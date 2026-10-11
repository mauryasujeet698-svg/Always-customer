"use strict";

const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");

const db = getFirestore();

// Scheduled cleanup has explicit per-run budgets. A large backlog is processed
// over successive runs instead of creating an unbounded write spike.
const MAX_OFFERS_PER_RUN = 450;
const MAX_STALE_RIDES_PER_RUN = 250;
const MAX_RECORDS_PER_COLLECTION_PER_RUN = 90;

async function expireCollectionGroup(query, limit = MAX_OFFERS_PER_RUN) {
  const snap = await query.limit(limit).get();
  if (snap.empty) return 0;
  const batch = db.batch();
  for (const doc of snap.docs) {
    batch.set(doc.ref, {
      status: "expired",
      expiredAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  }
  await batch.commit();
  return snap.size;
}

const expireStaleRideOffers = onSchedule(
  { schedule: "every 1 minutes", timeZone: "Asia/Kolkata", region: "asia-south1", maxInstances: 1 },
  async () => {
    const now = new Date();

    const expiredOffers = await expireCollectionGroup(
      db.collectionGroup("requests")
        .where("status", "==", "searching")
        .where("offerExpiresAt", "<=", now),
      MAX_OFFERS_PER_RUN
    );

    // Also terminate old unmatched ride requests themselves. Without this,
    // expired offer documents could disappear while the parent ride remained
    // in "searching" forever. Each record uses at most two writes (ride + PIN).
    const staleRides = await db.collection("autoRideRequests")
      .where("status", "==", "searching")
      .where("expiresAt", "<=", now)
      .limit(MAX_STALE_RIDES_PER_RUN)
      .get();

    if (!staleRides.empty) {
      const batch = db.batch();
      for (const ride of staleRides.docs) {
        batch.set(ride.ref, {
          status: "expired",
          customerActive: false,
          expiredAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
        batch.delete(db.collection("customerPrivatePins").doc("ride_" + ride.id));
      }
      await batch.commit();
    }

    console.log("ALLways bounded stale-work cleanup:", JSON.stringify({
      expiredOffers,
      expiredRides: staleRides.size,
      offerLimit: MAX_OFFERS_PER_RUN,
      rideLimit: MAX_STALE_RIDES_PER_RUN,
    }));
  }
);

const cleanupExpiredOperationalData = onSchedule(
  { schedule: "every 15 minutes", timeZone: "Asia/Kolkata", region: "asia-south1", maxInstances: 1 },
  async () => {
    const now = new Date();
    const targets = [
      "partnerPublicPresence",
      "customerPrivatePins",
      "checkoutIdempotency",
      "rideIdempotency",
      "serverRateLimits",
    ];
    const counts = {};
    let totalRemoved = 0;

    for (const collection of targets) {
      const snap = await db.collection(collection)
        .where("expiresAt", "<=", now)
        .limit(MAX_RECORDS_PER_COLLECTION_PER_RUN)
        .get();
      counts[collection] = snap.size;
      if (snap.empty) continue;

      const batch = db.batch();
      snap.docs.forEach((doc) => batch.delete(doc.ref));
      await batch.commit();
      totalRemoved += snap.size;
    }

    console.log("ALLways bounded operational-data cleanup:", JSON.stringify({
      removed: totalRemoved,
      perCollectionLimit: MAX_RECORDS_PER_COLLECTION_PER_RUN,
      counts,
    }));
  }
);

module.exports = { expireStaleRideOffers, cleanupExpiredOperationalData };
