"use strict";

const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");

const db = getFirestore();

async function expireCollectionGroup(query, terminalPatchFactory, limit = 450) {
  const snap = await query.limit(limit).get();
  if (snap.empty) return 0;
  const batch = db.batch();
  for (const doc of snap.docs) {
    batch.set(doc.ref, terminalPatchFactory(doc.data() || {}), { merge: true });
  }
  await batch.commit();
  return snap.size;
}

const expireStaleRideOffers = onSchedule(
  { schedule: "every 1 minutes", timeZone: "Asia/Kolkata", region: "asia-south1", maxInstances: 1 },
  async () => {
    const now = new Date();
    let expired = 0;
    // Expired offers are removed from the partner queue; the underlying ride
    // remains searching until the server's ride-expiry/matching policy resolves it.
    while (true) {
      const count = await expireCollectionGroup(
        db.collectionGroup("requests")
          .where("status", "==", "searching")
          .where("offerExpiresAt", "<=", now),
        () => ({ status: "expired", expiredAt: FieldValue.serverTimestamp() }),
        450
      );
      expired += count;
      if (count < 450) break;
    }
    console.log("ALLways expired stale ride offers:", expired);
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
    let removed = 0;
    for (const collection of targets) {
      while (true) {
        const snap = await db.collection(collection)
          .where("expiresAt", "<=", now)
          .limit(450)
          .get();
        if (snap.empty) break;
        const batch = db.batch();
        snap.docs.forEach((doc) => batch.delete(doc.ref));
        await batch.commit();
        removed += snap.size;
        if (snap.size < 450) break;
      }
    }
    console.log("ALLways cleaned expired operational records:", removed);
  }
);

module.exports = { expireStaleRideOffers, cleanupExpiredOperationalData };
