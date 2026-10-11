const crypto = require("node:crypto");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");

const db = getFirestore();
const CACHE_TTL_MS = 24 * 60 * 60 * 1000;
const RATE_WINDOW_MS = 60 * 1000;
const MAX_SEARCHES_PER_USER_PER_WINDOW = 30;

function validCoordinatePair(latitude, longitude) {
  return typeof latitude === "number" &&
    typeof longitude === "number" &&
    Number.isFinite(latitude) &&
    Number.isFinite(longitude) &&
    latitude >= -90 && latitude <= 90 &&
    longitude >= -180 && longitude <= 180;
}

function cacheKeyFor(query, latitude, longitude) {
  const normalized = query.toLowerCase().trim().replace(/\s+/g, " ");
  const locationBucket = validCoordinatePair(latitude, longitude)
    ? `${latitude.toFixed(2)},${longitude.toFixed(2)}`
    : "no-location";
  return crypto.createHash("sha256")
    .update(`${normalized}| ${locationBucket}`)
    .digest("hex");
}

function placeFromFeature(feature) {
  if (!feature || typeof feature !== "object") return null;
  const geometry = feature.geometry || {};
  const properties = feature.properties || {};
  const coordinates = geometry.coordinates;
  if (!Array.isArray(coordinates) || coordinates.length < 2) return null;

  const longitude = Number(coordinates[0]);
  const latitude = Number(coordinates[1]);
  if (!validCoordinatePair(latitude, longitude)) return null;

  const street = String(properties.street || "").trim();
  const houseNumber = String(properties.housenumber || properties.house_number || "").trim();
  const streetLine = [houseNumber, street].filter(Boolean).join(" ");
  const city = String(properties.city || properties.locality || properties.district || properties.county || "").trim();
  const name = String(properties.name || streetLine || city || "Place").trim();
  const parts = [
    String(properties.name || "").trim(),
    streetLine,
    city,
    String(properties.state || "").trim(),
    String(properties.postcode || "").trim(),
    String(properties.country || "").trim(),
  ].filter(Boolean);
  const address = [...new Set(parts)].join(", ") || name;

  return {
    name: name || "Place",
    address,
    lat: latitude,
    lon: longitude,
  };
}

async function enforcePerUserLimit(uid, nowMs) {
  const ref = db.collection("geocodingRateLimits").doc(uid);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const previous = snap.exists && Array.isArray(snap.data()?.requests)
      ? snap.data().requests
      : [];
    const recent = previous.filter((value) =>
      typeof value === "number" && nowMs - value >= 0 && nowMs - value < RATE_WINDOW_MS
    );
    if (recent.length >= MAX_SEARCHES_PER_USER_PER_WINDOW) {
      throw new HttpsError("resource-exhausted", "Too many place searches. Please wait a moment and try again.");
    }
    recent.push(nowMs);
    tx.set(ref, {
      requests: recent,
      expiresAt: Timestamp.fromMillis(nowMs + RATE_WINDOW_MS * 2),
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
}

const searchPlaces = onCall({
  region: "asia-south1",
  maxInstances: 30,
  timeoutSeconds: 10,
}, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in before searching for places.");

  const query = String(request.data?.query || "").replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();
  if (query.length < 2 || query.length > 120) {
    throw new HttpsError("invalid-argument", "Place search must be between 2 and 120 characters.");
  }

  const latitude = request.data?.latitude;
  const longitude = request.data?.longitude;
  const hasLocation = validCoordinatePair(latitude, longitude);
  const nowMs = Date.now();
  const cacheRef = db.collection("geocodingCache").doc(cacheKeyFor(
    query,
    hasLocation ? latitude : null,
    hasLocation ? longitude : null,
  ));

  // Count every callable request, including cache hits, to bound Firestore
  // read/write load as well as external geocoder spend.
  await enforcePerUserLimit(uid, nowMs);

  const cached = await cacheRef.get();
  if (cached.exists) {
    const data = cached.data() || {};
    const expiresAt = data.expiresAt;
    if (expiresAt && typeof expiresAt.toMillis === "function" && expiresAt.toMillis() > nowMs &&
        Array.isArray(data.places)) {
      return { places: data.places.slice(0, 10), cached: true };
    }
  }

  // Never silently send production traffic to an uncontracted public geocoder.
  // The deployment workflow requires an explicitly configured provider endpoint.
  const endpoint = String(process.env.GEOCODING_API_BASE_URL || "").trim();
  if (!endpoint) {
    throw new HttpsError("failed-precondition", "Place search is not configured yet. Please contact ALLways support.");
  }
  let url;
  try {
    url = new URL(endpoint);
  } catch (_) {
    throw new HttpsError("failed-precondition", "The geocoding provider endpoint is not configured correctly.");
  }
  if (url.protocol !== "https:") {
    throw new HttpsError("failed-precondition", "The geocoding provider must use HTTPS.");
  }
  url.searchParams.set("q", query);
  url.searchParams.set("limit", "10");
  url.searchParams.set("lang", "en");
  url.searchParams.set("zoom", "16");
  if (hasLocation) {
    url.searchParams.set("lat", String(latitude));
    url.searchParams.set("lon", String(longitude));
  }

  let response;
  try {
    response = await fetch(url, {
      headers: {
        Accept: "application/json",
        "User-Agent": "ALLways-Geocoding/1.0 (+https://github.com/mauryasujeet698-svg/Always-website)",
      },
      signal: AbortSignal.timeout(8000),
    });
  } catch (_) {
    throw new HttpsError("unavailable", "Place search is temporarily unavailable. Please try again.");
  }
  if (!response.ok) {
    if (response.status === 429) {
      throw new HttpsError("resource-exhausted", "The place search service is busy. Please try again shortly.");
    }
    throw new HttpsError("unavailable", "Place search is temporarily unavailable. Please try again.");
  }

  let payload;
  try {
    payload = await response.json();
  } catch (_) {
    throw new HttpsError("unavailable", "The place search service returned an invalid response.");
  }
  const features = Array.isArray(payload?.features) ? payload.features : [];
  const places = features.map(placeFromFeature).filter(Boolean).slice(0, 10);

  await cacheRef.set({
    places,
    expiresAt: Timestamp.fromMillis(nowMs + CACHE_TTL_MS),
    createdAt: FieldValue.serverTimestamp(),
  }, { merge: true });

  return { places, cached: false };
});

module.exports = {
  searchPlaces,
  // Exported for deterministic Node tests; these helpers do not access network or Firebase.
  _test: { validCoordinatePair, cacheKeyFor, placeFromFeature },
};
