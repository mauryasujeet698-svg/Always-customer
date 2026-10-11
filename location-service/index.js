"use strict";

const crypto = require("crypto");
const express = require("express");
const helmet = require("helmet");
const Redis = require("ioredis");
const { initializeApp, getApps } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { validateCoordinates, distanceKm, cellsForRadius } = require("./geo");

if (getApps().length === 0) initializeApp();
if (!process.env.REDIS_URL) throw new Error("REDIS_URL must point to the private Redis/Memorystore endpoint.");
if (!process.env.LOCATION_SERVICE_TOKEN) throw new Error("LOCATION_SERVICE_TOKEN must be supplied via Secret Manager.");

const db = getFirestore();
const redis = new Redis(process.env.REDIS_URL, {
  lazyConnect: true,
  maxRetriesPerRequest: 1,
  enableOfflineQueue: false,
  connectTimeout: 3000,
});
redis.on("error", (error) => console.error("Redis connection error:", error.message));

const app = express();
app.disable("x-powered-by");
app.use(helmet());
app.use(express.json({ limit: "8kb", strict: true }));

const SHIFT_TTL_SECONDS = 14 * 60 * 60;
const LOCATION_TTL_SECONDS = 180;
const LOCATION_RATE_LIMIT_PER_MINUTE = 40;
const PRESENCE_KEY = "presence:last_seen";
const allowedRole = (role) => role === "carrier" || role === "delivery_partner";
const profileCollection = (role) => role === "carrier" ? "ridePartners" : "deliveryPartners";
const locationKey = (role, uid) => "location:" + role + ":" + uid;
const shiftKey = (role, uid) => "shift:" + role + ":" + uid;
const cellKey = (role, cell) => "cell:" + role + ":" + cell;
const rateKey = (uid) => "ratelimit:location:" + uid;
const shiftMember = (role, uid) => role + ":" + uid;

function clearLocation(role) {
  const fields = role === "carrier"
    ? ["carrierLat", "carrierLng", "carrierLocationUpdatedAt", "lastLocationAt"]
    : ["deliveryLat", "deliveryLng", "lastLat", "lastLng", "deliveryLocationUpdatedAt", "lastLocationAt"];
  return Object.fromEntries(fields.map((field) => [field, FieldValue.delete()]));
}
function isTerminal(status) {
  return ["completed", "delivered", "cancelled", "rejected", "expired"].includes(String(status || "").toLowerCase());
}
function sendError(res, status, message) {
  return res.status(status).json({ ok: false, error: message });
}
async function requireFirebaseUser(req, res, next) {
  try {
    const header = String(req.headers.authorization || "");
    const match = header.match(/^Bearer\s+(.+)$/i);
    if (!match) return sendError(res, 401, "Firebase ID token required.");
    req.user = await getAuth().verifyIdToken(match[1], true);
    return next();
  } catch (_) {
    return sendError(res, 401, "Firebase ID token invalid or expired.");
  }
}
function requireInternal(req, res, next) {
  const expected = Buffer.from(process.env.LOCATION_SERVICE_TOKEN || "");
  const supplied = Buffer.from(String(req.get("x-location-service-token") || ""));
  if (!expected.length || expected.length !== supplied.length || !crypto.timingSafeEqual(expected, supplied)) {
    return sendError(res, 403, "Internal service authorization required.");
  }
  return next();
}
async function removePresence(role, uid) {
  const locKey = locationKey(role, uid);
  const oldCell = await redis.hget(locKey, "cell");
  const multi = redis.multi();
  if (oldCell) multi.srem(cellKey(role, oldCell), uid);
  multi.zrem(PRESENCE_KEY, shiftMember(role, uid));
  multi.del(locKey);
  multi.del(shiftKey(role, uid));
  await multi.exec();
  await db.collection("partnerPublicPresence").doc(uid).delete().catch(() => {});
}

app.get("/healthz", (_req, res) => res.status(200).json({ ok: true }));
app.get("/readyz", async (_req, res) => {
  try {
    await redis.ping();
    return res.status(200).json({ ok: true, redis: "ready" });
  } catch (_) {
    return sendError(res, 503, "Redis is not ready.");
  }
});

/**
 * The only supported shift boundary when LOCATION_SERVICE_URL is configured.
 * It verifies the authenticated partner and persists the shift state before the
 * app begins sending coordinates.
 */
app.post("/v1/shift", requireFirebaseUser, async (req, res) => {
  const uid = req.user.uid;
  const role = String(req.body?.role || "").trim().toLowerCase();
  const online = req.body?.online;
  if (!allowedRole(role) || typeof online !== "boolean") return sendError(res, 400, "Valid role and boolean online state are required.");
  try {
    await redis.ping();
    const profileRef = db.collection(profileCollection(role)).doc(uid);
    const pre = await profileRef.get();
    if (!pre.exists) return sendError(res, 403, "Partner profile not found.");
    const previous = pre.data() || {};
    if (String(previous.approvalStatus || "").toLowerCase() !== "approved") return sendError(res, 403, "Admin approval is required.");
    if (["suspended", "blocked", "disabled"].includes(String(previous.accountStatus || "").toLowerCase())) return sendError(res, 403, "Partner account is not allowed to work.");

    if (online && String(previous.shiftStatus || "").toLowerCase() === "on_duty") {
      const cached = await redis.hget(shiftKey(role, uid), "shiftSessionId");
      const existingId = String(previous.shiftSessionId || "");
      if (cached && existingId && cached === existingId) {
        await redis.hset(shiftKey(role, uid), "locationTrackingActive", "1");
        await redis.expire(shiftKey(role, uid), SHIFT_TTL_SECONDS);
        await db.collection("partnerPublicPresence").doc(uid).set({
          uid, role, displayName: previous.displayName || previous.name || "",
          vehicleType: previous.vehicleType || "", onDuty: true,
          expiresAt: new Date(Date.now() + 5 * 60 * 1000),
          lastSeenAt: FieldValue.serverTimestamp(),
        }, { merge: true });
        return res.status(200).json({ ok: true, shiftSessionId: existingId, alreadyOnDuty: true });
      }
    }

    const sessionId = online ? crypto.randomUUID() : null;
    const result = await db.runTransaction(async (tx) => {
      const snap = await tx.get(profileRef);
      if (!snap.exists) throw Object.assign(new Error("Partner profile not found."), { statusCode: 403 });
      const profile = snap.data() || {};
      if (String(profile.approvalStatus || "").toLowerCase() !== "approved") throw Object.assign(new Error("Admin approval is required."), { statusCode: 403 });
      if (online) {
        if (String(profile.activeRideId || profile.currentOrderId || "").trim() ||
            ["on_trip", "on_delivery"].includes(String(profile.status || "").toLowerCase())) {
          throw Object.assign(new Error("Finish or resume the current job instead of starting a new shift."), { statusCode: 409 });
        }
        const now = FieldValue.serverTimestamp();
        tx.update(profileRef, {
          status: "online", dutyStatus: "online", shiftStatus: "on_duty",
          locationTrackingActive: true,
          availableForRides: role === "carrier",
          availableForDeliveries: role === "delivery_partner",
          isOnline: true,
          shiftSessionId: sessionId,
          shiftStartedAt: now,
          lastSeenAt: now,
          shiftEndedAt: FieldValue.delete(),
          trackingAttentionRequired: false,
          statusUpdatedAt: now,
        });
        return { shiftSessionId: sessionId };
      }

      const activeId = role === "carrier" ? String(profile.activeRideId || "").trim() : String(profile.currentOrderId || "").trim();
      if (activeId) {
        const jobRef = db.collection(role === "carrier" ? "autoRideRequests" : "orders").doc(activeId);
        const job = await tx.get(jobRef);
        if (job.exists && !isTerminal(job.data()?.status)) {
          throw Object.assign(new Error("Complete or resolve the active job before ending your shift."), { statusCode: 409 });
        }
      } else if (["on_trip", "on_delivery"].includes(String(profile.status || "").toLowerCase())) {
        throw Object.assign(new Error("An active job is still recorded. Contact support before ending your shift."), { statusCode: 409 });
      }
      const now = FieldValue.serverTimestamp();
      tx.update(profileRef, {
        status: "offline", dutyStatus: "offline", shiftStatus: "off_duty",
        locationTrackingActive: false,
        availableForRides: false, availableForDeliveries: false, isOnline: false,
        shiftSessionId: FieldValue.delete(),
        shiftEndedAt: now, statusUpdatedAt: now,
        trackingAttentionRequired: false,
        ...clearLocation(role),
      });
      return { shiftSessionId: null };
    });

    if (online) {
      await redis.hset(shiftKey(role, uid), {
        uid, role, shiftSessionId: result.shiftSessionId,
        profileCollection: profileCollection(role),
        locationTrackingActive: "1",
        shiftStartedMs: String(Date.now()),
      });
      await redis.expire(shiftKey(role, uid), SHIFT_TTL_SECONDS);
      const profile = (await profileRef.get()).data() || {};
      await db.collection("partnerPublicPresence").doc(uid).set({
        uid, role, displayName: profile.displayName || profile.name || "",
        vehicleType: profile.vehicleType || "", onDuty: true,
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      return res.status(200).json({ ok: true, shiftSessionId: result.shiftSessionId });
    }
    await removePresence(role, uid);
    return res.status(200).json({ ok: true, shiftSessionId: null });
  } catch (error) {
    const status = Number(error.statusCode) || (String(error.message || "").includes("redis") ? 503 : 500);
    if (status === 500) console.error("Shift state change failed:", error.message);
    return sendError(res, status, status === 500 ? "Shift could not be updated. Try again." : String(error.message || "Shift change rejected."));
  }
});

/**
 * High-frequency location writes are kept in Redis/H3. Firestore receives only
 * a low-frequency heartbeat and a bounded active-trip projection from the apps.
 */
app.post("/v1/locations", requireFirebaseUser, async (req, res) => {
  const uid = req.user.uid;
  const role = String(req.body?.role || "").trim().toLowerCase();
  const shiftSessionId = String(req.body?.shiftSessionId || "");
  if (!allowedRole(role) || !shiftSessionId) return sendError(res, 400, "Role and active shift session are required.");
  let point;
  try {
    point = validateCoordinates(req.body?.latitude, req.body?.longitude);
  } catch (error) {
    return sendError(res, 400, error.message);
  }
  try {
    const count = await redis.incr(rateKey(uid));
    if (count === 1) await redis.expire(rateKey(uid), 60);
    if (count > LOCATION_RATE_LIMIT_PER_MINUTE) return sendError(res, 429, "Location update rate limit exceeded.");

    const sKey = shiftKey(role, uid);
    const [storedSession, trackingActive] = await redis.hmget(sKey, "shiftSessionId", "locationTrackingActive");
    if (!storedSession || storedSession !== shiftSessionId || trackingActive !== "1") {
      return sendError(res, 409, "Shift is closed or location tracking is suspended. Go off duty and back on duty.");
    }
    const { origin, cells } = cellsForRadius(point.latitude, point.longitude, 0.5);
    const cell = origin;
    const locKey = locationKey(role, uid);
    const oldCell = await redis.hget(locKey, "cell");
    const now = Date.now();
    const member = shiftMember(role, uid);
    const multi = redis.multi();
    if (oldCell && oldCell !== cell) multi.srem(cellKey(role, oldCell), uid);
    multi.hset(locKey, {
      uid, role, lat: String(point.latitude), lng: String(point.longitude), cell,
      shiftSessionId, lastSeenMs: String(now),

    });
    multi.expire(locKey, LOCATION_TTL_SECONDS);
    multi.sadd(cellKey(role, cell), uid);
    multi.expire(cellKey(role, cell), LOCATION_TTL_SECONDS);
    multi.zadd(PRESENCE_KEY, String(now), member);
    multi.hset(sKey, "lastSeenMs", String(now));
    multi.expire(sKey, SHIFT_TTL_SECONDS);
    await multi.exec();

    // Throttle durable heartbeats to one per 120 seconds; the GPS stream itself
    // never creates a Firestore write per point when the Redis service is active.
    const heartbeat = await redis.set("heartbeat:" + role + ":" + uid, "1", "EX", 120, "NX");
    if (heartbeat) {
      const profileRef = db.collection(profileCollection(role)).doc(uid);
      const profile = (await profileRef.get()).data() || {};
      await redis.hset(locKey, {
        vehicleType: String(profile.vehicleType || ""),
        approved: String(profile.approvalStatus || "").toLowerCase() === "approved" ? "1" : "0",
        available: (role === "carrier" ? profile.availableForRides : profile.availableForDeliveries) === false ? "0" : "1",
        activeJob: String(profile.activeRideId || profile.currentOrderId || "").trim() ? "1" : "0",
      });
      await profileRef.update({
        lastSeenAt: FieldValue.serverTimestamp(),
        locationTrackingActive: true,
        trackingAttentionRequired: false,
      });
      await db.collection("partnerPublicPresence").doc(uid).set({
        uid, role,
        displayName: profile.displayName || profile.name || "",
        vehicleType: profile.vehicleType || "",
        onDuty: String(profile.shiftStatus || "").toLowerCase() === "on_duty",
        locationCell: cell,
        expiresAt: new Date(Date.now() + 5 * 60 * 1000),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
    }
    return res.status(202).json({ ok: true, indexed: true, expiresInSeconds: LOCATION_TTL_SECONDS });
  } catch (error) {
    console.error("Location update failed:", error.message);
    return sendError(res, 503, "Location service is temporarily unavailable.");
  }
});

/** Internal Cloud Functions-only dispatch query: it never returns phone numbers. */
app.post("/v1/match", requireInternal, async (req, res) => {
  const role = String(req.body?.role || "").trim().toLowerCase();
  if (!allowedRole(role)) return sendError(res, 400, "Unsupported matching role.");
  let point;
  try { point = validateCoordinates(req.body?.latitude, req.body?.longitude); }
  catch (error) { return sendError(res, 400, error.message); }
  const radiusKm = Number(req.body?.radiusKm || 7);
  if (!Number.isFinite(radiusKm) || radiusKm <= 0 || radiusKm > 50) return sendError(res, 400, "radiusKm must be between 0 and 50.");
  const requestedVehicle = String(req.body?.vehicleType || "").trim().toLowerCase();
  const maxResults = Math.max(1, Math.min(50, Number.parseInt(req.body?.limit || "20", 10) || 20));
  try {
    const { cells } = cellsForRadius(point.latitude, point.longitude, radiusKm);
    const uids = new Set();
    for (let i = 0; i < cells.length; i += 150) {
      const part = cells.slice(i, i + 150);
      const pipeline = redis.pipeline();
      for (const cell of part) pipeline.smembers(cellKey(role, cell));
      const replies = await pipeline.exec();
      for (const reply of replies || []) {
        if (!reply || reply[0] || !Array.isArray(reply[1])) continue;
        for (const uid of reply[1]) uids.add(uid);
      }
      if (uids.size >= 2500) break;
    }

    const candidates = [];
    const all = Array.from(uids);
    for (let i = 0; i < all.length; i += 100) {
      const batch = all.slice(i, i + 100);
      const pipeline = redis.pipeline();
      for (const uid of batch) pipeline.hgetall(locationKey(role, uid));
      const replies = await pipeline.exec();
      const profiles = await db.getAll(...batch.map((uid) => db.collection(profileCollection(role)).doc(uid)));
      for (let j = 0; j < batch.length; j++) {
        const reply = replies?.[j];
        if (!reply || reply[0]) continue;
        const cached = reply[1] || {};
        const profileSnap = profiles[j];
        if (!profileSnap?.exists) continue;
        const profile = profileSnap.data() || {};
        const uid = batch[j];
        const shift = await redis.hgetall(shiftKey(role, uid));
        const session = String(profile.shiftSessionId || "");
        const effectiveVehicle = String(profile.vehicleType || cached.vehicleType || "").toLowerCase();
        const approved = String(profile.approvalStatus || "").toLowerCase() === "approved";
        const onDuty = String(profile.shiftStatus || "").toLowerCase() === "on_duty";
        const available = role === "carrier" ? profile.availableForRides !== false : profile.availableForDeliveries !== false;
        const activeJob = role === "carrier"
          ? String(profile.activeRideId || "").trim()
          : String(profile.currentOrderId || "").trim();
        if (!cached.uid || cached.role !== role || !approved || !onDuty || !available || activeJob) continue;
        if (!session || session !== String(cached.shiftSessionId || "") ||
            session !== String(shift.shiftSessionId || "")) continue;
        if (profile.locationTrackingActive === false || Date.now() - Number(cached.lastSeenMs || 0) > 90000) continue;
        if (requestedVehicle && effectiveVehicle !== requestedVehicle) continue;
        const lat = Number(cached.lat), lng = Number(cached.lng);
        if (!Number.isFinite(lat) || !Number.isFinite(lng)) continue;
        const km = distanceKm(point.latitude, point.longitude, lat, lng);
        if (km <= radiusKm) candidates.push({ uid, distanceKm: km, vehicleType: effectiveVehicle });
      }
    }
    candidates.sort((a, b) => a.distanceKm - b.distanceKm);
    return res.status(200).json({ ok: true, candidates: candidates.slice(0, maxResults) });
  } catch (error) {
    console.error("H3 match failed:", error.message);
    return sendError(res, 503, "Nearby matching is temporarily unavailable.");
  }
});

/** Cloud Scheduler can call this with the internal service token every minute. */
app.post("/internal/sweep-stale", requireInternal, async (req, res) => {
  const cutoff = Date.now() - 120000;
  const limit = Math.max(1, Math.min(500, Number.parseInt(req.body?.limit || "300", 10) || 300));
  try {
    const stale = await redis.zrangebyscore(PRESENCE_KEY, "-inf", cutoff, "LIMIT", 0, limit);
    let cleaned = 0;
    for (const member of stale) {
      const split = member.indexOf(":");
      const role = member.slice(0, split), uid = member.slice(split + 1);
      if (!allowedRole(role) || !uid) { await redis.zrem(PRESENCE_KEY, member); continue; }
      const lKey = locationKey(role, uid), sKey = shiftKey(role, uid);
      const [loc, session] = await Promise.all([redis.hgetall(lKey), redis.hgetall(sKey)]);
      const profileRef = db.collection(profileCollection(role)).doc(uid);
      const profileSnap = await profileRef.get();
      const profile = profileSnap.data() || {};
      const activeId = role === "carrier" ? String(profile.activeRideId || "").trim() : String(profile.currentOrderId || "").trim();
      let active = false, jobRef = null;
      if (activeId) {
        jobRef = db.collection(role === "carrier" ? "autoRideRequests" : "orders").doc(activeId);
        const job = await jobRef.get();
        active = job.exists && !isTerminal(job.data()?.status);
      }
      const oldCell = loc.cell;
      if (oldCell) await redis.srem(cellKey(role, oldCell), uid);
      await redis.del(lKey);
      await redis.zrem(PRESENCE_KEY, member);
      if (active) {
        await redis.hset(sKey, "locationTrackingActive", "0");
        await profileRef.update({ locationTrackingActive: false, trackingAttentionRequired: true, ...clearLocation(role) });
        if (jobRef) await jobRef.update(role === "carrier"
          ? { driverLat: FieldValue.delete(), driverLng: FieldValue.delete(), driverLocationUpdatedAt: FieldValue.delete() }
          : { carrierLat: FieldValue.delete(), carrierLng: FieldValue.delete(), carrierLocationUpdatedAt: FieldValue.delete() }).catch(() => {});
      } else if (profileSnap.exists && String(profile.shiftStatus || "").toLowerCase() === "on_duty") {
        await profileRef.update({
          status: "offline", dutyStatus: "offline", shiftStatus: "off_duty",
          locationTrackingActive: false, availableForRides: false, availableForDeliveries: false, isOnline: false,
          shiftSessionId: FieldValue.delete(), shiftEndedAt: FieldValue.serverTimestamp(),
          trackingAttentionRequired: true, ...clearLocation(role),
        });
        await redis.del(sKey);
        await db.collection("partnerPublicPresence").doc(uid).delete().catch(() => {});
      } else if (session.shiftSessionId) {
        await redis.del(sKey);
      }
      cleaned++;
    }
    return res.status(200).json({ ok: true, cleaned });
  } catch (error) {
    console.error("Stale location sweep failed:", error.message);
    return sendError(res, 503, "Stale location cleanup failed.");
  }
});

const port = Number(process.env.PORT || 8080);
if (require.main === module) {
  app.listen(port, "0.0.0.0", () => console.log("ALLways location service listening on " + port));
}
module.exports = { app, redis };
