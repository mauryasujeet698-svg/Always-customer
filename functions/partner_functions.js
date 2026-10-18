const crypto = require("node:crypto");
const {getApps, initializeApp} = require("firebase-admin/app");
const {getFirestore, FieldValue, Timestamp} = require("firebase-admin/firestore");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {onDocumentCreated, onDocumentUpdated} = require("firebase-functions/v2/firestore");

if (!getApps().length) initializeApp();
const db = getFirestore();

function requireUid(request) {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign-in required.");
  return request.auth.uid;
}
function text(value) { return value == null ? "" : String(value).trim(); }
function num(value) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (value == null || value === "") return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}
function hasValue(value) { return text(value).length > 0; }
function partnerRef(role, uid) {
  if (role === "carrier") return db.collection("ridePartners").doc(uid);
  if (role === "delivery_partner") return db.collection("deliveryPartners").doc(uid);
  throw new HttpsError("invalid-argument", "Unsupported partner role.");
}
function hasActiveJob(profile, role) {
  return role === "carrier"
    ? hasValue(profile.activeRideId)
    : hasValue(profile.currentOrderId) || hasValue(profile.pendingOrderId);
}
function haversineKm(aLat, aLng, bLat, bLng) {
  const rad = (value) => value * Math.PI / 180;
  const dLat = rad(bLat - aLat);
  const dLng = rad(bLng - aLng);
  const a = Math.sin(dLat / 2) ** 2
    + Math.cos(rad(aLat)) * Math.cos(rad(bLat)) * Math.sin(dLng / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}
function driverLocation(profile) {
  const lat = num(profile.carrierLat ?? profile.latitude ?? profile.lastLat);
  const lng = num(profile.carrierLng ?? profile.longitude ?? profile.lastLng);
  return lat == null || lng == null ? null : {lat, lng};
}
function rideLocation(ride) {
  const lat = num(ride.pickupLatitude ?? ride.pickupLat);
  const lng = num(ride.pickupLongitude ?? ride.pickupLng);
  return lat == null || lng == null ? null : {lat, lng};
}

async function offerRideIfEligible(rideRef, driverRef) {
  return db.runTransaction(async (tx) => {
    const [rideSnap, driverSnap] = await Promise.all([
      tx.get(rideRef),
      tx.get(driverRef),
    ]);
    if (!rideSnap.exists || !driverSnap.exists) return false;
    const ride = rideSnap.data() || {};
    const driver = driverSnap.data() || {};
    if (text(ride.status).toLowerCase() !== "searching") return false;
    if (hasValue(ride.driverUid) || hasValue(ride.carrierUid)) return false;
    if (text(driver.approvalStatus).toLowerCase() !== "approved"
        || text(driver.role) !== "carrier"
        || text(driver.status).toLowerCase() !== "online"
        || driver.availableForRides === false
        || hasActiveJob(driver, "carrier")) return false;

    const wantedVehicle = text(ride.rideType || "bike").toLowerCase();
    if (!["bike", "auto", "car"].includes(wantedVehicle)) return false;
    if (text(driver.vehicleType || "bike").toLowerCase() !== wantedVehicle) return false;
    const pickup = rideLocation(ride);
    const current = driverLocation(driver);
    if (!pickup || !current) return false;

    const requestedRadius = num(driver.matchingRadiusKm);
    const radiusKm = requestedRadius == null ? 30 : Math.max(1, Math.min(requestedRadius, 50));
    if (haversineKm(pickup.lat, pickup.lng, current.lat, current.lng) > radiusKm) return false;

    const offerRef = db.collection("rideOffers").doc(driverRef.id)
      .collection("requests").doc(rideRef.id);
    const offerSnap = await tx.get(offerRef);
    if (offerSnap.exists) return false;

    const now = Date.now();
    tx.create(offerRef, {
      ...ride,
      id: text(ride.id) || rideRef.id,
      rideId: rideRef.id,
      status: "searching",
      customerActive: true,
      rejected: false,
      rejectedBy: [],
      offerExpiresAt: Timestamp.fromMillis(now + 30 * 60 * 1000),
      offeredAt: FieldValue.serverTimestamp(),
    });
    return true;
  });
}

/** Shift status is server-authoritative; approval and active-job state are checked here. */
exports.setPartnerShift = onCall(async (request) => {
  const uid = requireUid(request);
  const role = text(request.data && request.data.role);
  const online = request.data && request.data.online === true;
  const ref = partnerRef(role, uid);
  const snap = await ref.get();

  if (!snap.exists) {
    throw new HttpsError("failed-precondition", "Complete partner registration first.");
  }
  const profile = snap.data() || {};
  if (text(profile.uid) !== uid || text(profile.role) !== role) {
    throw new HttpsError("permission-denied", "The partner profile does not match this account.");
  }
  if (text(profile.approvalStatus).toLowerCase() !== "approved") {
    throw new HttpsError("permission-denied", "Admin approval is required before going online.");
  }

  const active = hasActiveJob(profile, role);
  if (!online && active) {
    throw new HttpsError("failed-precondition", "Finish your active job before going offline.");
  }

  const shiftSessionId = online ? crypto.randomUUID() : null;
  const available = online && !active;
  const status = !online ? "offline"
    : active ? (role === "carrier" ? "on_trip" : "on_delivery")
      : "online";

  const patch = {
    status,
    dutyStatus: online ? "online" : "offline",
    shiftStatus: online ? "on_duty" : "off_duty",
    isOnline: online,
    availableForRides: role === "carrier" && available,
    availableForDeliveries: role === "delivery_partner" && available,
    shiftSessionId,
    statusUpdatedAt: FieldValue.serverTimestamp(),
    lastSeenAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  };
  if (online) patch.shiftStartedAt = FieldValue.serverTimestamp();
  else patch.shiftEndedAt = FieldValue.serverTimestamp();

  await ref.set(patch, {merge: true});
  return {ok: true, role, online, shiftSessionId};
});

/** Offer newly requested rides to eligible drivers using private per-driver documents. */
exports.dispatchRideOffers = onDocumentCreated("autoRideRequests/{rideId}", async (event) => {
  const rideId = text(event.params.rideId);
  const ride = event.data && event.data.data();
  if (!ride || text(ride.status).toLowerCase() !== "searching" || !text(ride.customerId)) return;
  if (!rideLocation(ride)) return;

  const drivers = await db.collection("ridePartners")
    .where("approvalStatus", "==", "approved")
    .where("status", "==", "online")
    .limit(400)
    .get();

  let offered = 0;
  for (const driverDoc of drivers.docs) {
    try {
      if (await offerRideIfEligible(db.collection("autoRideRequests").doc(rideId), driverDoc.ref)) {
        offered++;
      }
    } catch (error) {
      console.error("Failed to offer ride", rideId, driverDoc.id, error);
    }
  }
  return {rideId, offered};
});

/** A driver who comes online should also receive still-searching rides. */
exports.offerWaitingRidesToDriver = onDocumentUpdated("ridePartners/{driverUid}", async (event) => {
  const before = event.data && event.data.before && event.data.before.data();
  const after = event.data && event.data.after && event.data.after.data();
  if (!before || !after) return;
  const becameEligible = text(after.approvalStatus).toLowerCase() === "approved"
    && text(after.status).toLowerCase() === "online"
    && text(before.status).toLowerCase() !== "online";
  if (!becameEligible) return;

  const driverRef = db.collection("ridePartners").doc(event.params.driverUid);
  const rides = await db.collection("autoRideRequests")
    .where("status", "==", "searching")
    .limit(100)
    .get();

  let offered = 0;
  for (const ride of rides.docs) {
    try {
      if (await offerRideIfEligible(ride.ref, driverRef)) offered++;
    } catch (error) {
      console.error("Failed to match waiting ride", ride.id, event.params.driverUid, error);
    }
  }
  return {driverUid: event.params.driverUid, offered};
});

/** The offer must exist and remain valid; Firestore transaction arbitrates racing drivers. */
exports.acceptRide = onCall(async (request) => {
  const uid = requireUid(request);
  const rideId = text(request.data && request.data.rideId);
  if (!rideId) throw new HttpsError("invalid-argument", "rideId is required.");

  const rideRef = db.collection("autoRideRequests").doc(rideId);
  const offerRef = db.collection("rideOffers").doc(uid).collection("requests").doc(rideId);
  const driverRef = db.collection("ridePartners").doc(uid);

  await db.runTransaction(async (tx) => {
    const [rideSnap, offerSnap, driverSnap] = await Promise.all([
      tx.get(rideRef),
      tx.get(offerRef),
      tx.get(driverRef),
    ]);
    if (!rideSnap.exists) throw new HttpsError("not-found", "Ride not found.");
    if (!offerSnap.exists) throw new HttpsError("permission-denied", "This ride was not offered to your account.");
    if (!driverSnap.exists) throw new HttpsError("failed-precondition", "Complete driver registration first.");

    const ride = rideSnap.data() || {};
    const offer = offerSnap.data() || {};
    const driver = driverSnap.data() || {};
    if (text(driver.uid) !== uid || text(driver.role) !== "carrier"
        || text(driver.approvalStatus).toLowerCase() !== "approved") {
      throw new HttpsError("permission-denied", "Admin approval is required before accepting rides.");
    }
    if (text(driver.status).toLowerCase() !== "online"
        || driver.availableForRides !== true
        || !hasValue(driver.shiftSessionId)
        || hasActiveJob(driver, "carrier")) {
      throw new HttpsError("failed-precondition", "Go online and wait for a new ride offer.");
    }
    if (text(offer.status).toLowerCase() !== "searching"
        || offer.rejected === true
        || offer.customerActive === false) {
      throw new HttpsError("failed-precondition", "This ride offer is no longer available.");
    }
    if (text(ride.status).toLowerCase() !== "searching"
        || hasValue(ride.driverUid) || hasValue(ride.carrierUid)) {
      throw new HttpsError("aborted", "Another driver has already accepted this ride.");
    }
    const rejectedBy = Array.isArray(ride.rejectedBy) ? ride.rejectedBy : [];
    if (rejectedBy.includes(uid)) {
      throw new HttpsError("failed-precondition", "You already rejected this ride.");
    }
    const expiry = offer.offerExpiresAt;
    if (expiry && typeof expiry.toMillis === "function" && expiry.toMillis() < Date.now()) {
      throw new HttpsError("deadline-exceeded", "This ride offer has expired.");
    }

    tx.update(rideRef, {
      driverUid: uid,
      driverName: driver.name || driver.displayName || "ALLways Driver Partner",
      driverPhone: driver.phone || driver.mobileNumber || "",
      status: "accepted",
      acceptedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    tx.update(driverRef, {
      status: "on_trip",
      availableForRides: false,
      activeRideId: rideId,
      lastAcceptedAt: FieldValue.serverTimestamp(),
      statusUpdatedAt: FieldValue.serverTimestamp(),
    });
    tx.update(offerRef, {
      status: "accepted",
      acceptedBy: uid,
      customerActive: true,
      updatedAt: FieldValue.serverTimestamp(),
    });
  });

  const offers = await db.collectionGroup("requests").where("rideId", "==", rideId).get();
  const batch = db.batch();
  let changed = 0;
  for (const doc of offers.docs) {
    const offeredTo = doc.ref.parent.parent ? doc.ref.parent.parent.id : "";
    if (!offeredTo || offeredTo === uid) continue;
    batch.set(doc.ref, {
      status: "assigned",
      assignedDriverUid: uid,
      customerActive: false,
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
    changed++;
  }
  if (changed > 0) await batch.commit();
  return {ok: true, rideId};
});

/** Keep offers from remaining active after a ride is accepted, cancelled or completed. */
exports.syncRideOfferStates = onDocumentUpdated("autoRideRequests/{rideId}", async (event) => {
  const before = event.data && event.data.before && event.data.before.data();
  const after = event.data && event.data.after && event.data.after.data();
  const rideId = text(event.params.rideId);
  if (!before || !after || !rideId) return;
  const beforeStatus = text(before.status).toLowerCase();
  const afterStatus = text(after.status).toLowerCase();
  if (beforeStatus === afterStatus && text(before.driverUid) === text(after.driverUid)) return;
  if (afterStatus === "searching") return;

  const assignedUid = text(after.driverUid);
  const offers = await db.collectionGroup("requests").where("rideId", "==", rideId).get();
  const batch = db.batch();
  let count = 0;
  for (const doc of offers.docs) {
    const offeredTo = doc.ref.parent.parent ? doc.ref.parent.parent.id : "";
    const finalStatus = afterStatus === "accepted"
      ? (offeredTo === assignedUid ? "accepted" : "assigned")
      : afterStatus;
    batch.set(doc.ref, {
      status: finalStatus,
      customerActive: afterStatus === "accepted" && offeredTo === assignedUid,
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
    count++;
  }
  if (count) await batch.commit();
  return {rideId, synchronizedOffers: count};
});
