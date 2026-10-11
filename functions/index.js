const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const crypto = require("crypto");

initializeApp();

const db = getFirestore();

// Partner shift, assignment, and stale-location controls.
Object.assign(exports, require('./partner_security'));
Object.assign(exports, require('./customer_orders'));
Object.assign(exports, require('./customer_rides'));
Object.assign(exports, require('./retention'));

const { getMessaging } = require("firebase-admin/messaging");

function notificationChannelForRole(role) {
  const r = String(role || "").toLowerCase();
  if (r === "carrier" || r === "delivery_partner") return "allways_urgent_v2";
  if (r === "admin") return "allways_updates_v2";
  return "allways_updates";
}

async function tokensForUser(uid) {
  const ref = db.collection("fcmTokens").doc(uid);
  const tokens = new Set();
  const rootSnap = await ref.get();
  const root = rootSnap.data() || {};

  // The root token is retained for backwards compatibility. Respect its
  // notification switch, but still inspect individual devices independently.
  const rootToken = String(root.token || "").trim();
  if (rootToken && root.notificationsEnabled !== false) tokens.add(rootToken);

  const snap = await ref.collection("tokens").get();
  for (const doc of snap.docs) {
    const data = doc.data() || {};
    if (data.notificationsEnabled === false) continue;
    const token = String(data.token || doc.id || "").trim();
    if (token) tokens.add(token);
  }
  return [...tokens];
}

async function sendToUser(uid, title, body, data = {}, role = "") {
  const tokens = await tokensForUser(uid);
  if (!tokens.length) return { successCount: 0, failureCount: 0 };

  const rootRef = db.collection("fcmTokens").doc(uid);
  const channelId = notificationChannelForRole(role);
  const urgent = channelId === "allways_urgent_v2";
  const messageBase = {
    notification: { title: String(title || "ALLways"), body: String(body || "") },
    data: Object.fromEntries(Object.entries({ ...data, title: String(title || "ALLways"), body: String(body || "") }).map(([k, v]) => [k, String(v ?? "")])),
    android: {
      priority: "high",
      notification: {
        channelId,
        sound: "default",
        defaultSound: true,
        defaultVibrateTimings: true,
        vibrateTimingsMillis: urgent ? [0, 450, 180, 450, 180, 700] : [0, 250, 120, 250],
        priority: urgent ? "max" : "high",
      },
    },
  };

  const result = await getMessaging().sendEachForMulticast({ ...messageBase, tokens });
  const invalid = [];
  result.responses.forEach((response, index) => {
    if (!response.success) {
      const code = response.error?.code || "";
      if (code.includes("registration-token-not-registered") || code.includes("invalid-registration-token")) {
        invalid.push(tokens[index]);
      }
    }
  });

  if (invalid.length) {
    const batch = db.batch();
    for (const token of invalid) {
      batch.delete(rootRef.collection("tokens").doc(token));
    }
    const root = await rootRef.get();
    const rootToken = String(root.data()?.token || "").trim();
    if (rootToken && invalid.includes(rootToken)) {
      batch.set(rootRef, {
        token: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
    }
    await batch.commit();
  }

  if (result.failureCount > 0) {
    // Log counts and error codes only; never log device tokens.
    const failures = result.responses
      .filter((response) => !response.success)
      .map((response) => String(response.error?.code || "unknown"));
    console.warn("ALLways FCM user send had failures", {
      failureCount: result.failureCount,
      successCount: result.successCount,
      errorCodes: [...new Set(failures)],
    });
  }
  return { successCount: result.successCount, failureCount: result.failureCount };
}

async function sendToTopic(topic, title, body, data = {}) {
  const channelId = "allways_updates";
  return getMessaging().send({
    topic,
    notification: { title: String(title || "ALLways"), body: String(body || "") },
    data: Object.fromEntries(Object.entries({ ...data, title: String(title || "ALLways"), body: String(body || "") }).map(([k, v]) => [k, String(v ?? "")])),
    android: {
      priority: "high",
      notification: {
        channelId,
        sound: "default",
        defaultSound: true,
        defaultVibrateTimings: true,
        vibrateTimingsMillis: [0, 250, 120, 250],
        priority: "high",
      },
    },
  });
}

function distanceKm(lat1, lon1, lat2, lon2) {
  const R = 6371;
  const dLat = ((lat2 - lat1) * Math.PI) / 180;
  const dLon = ((lon2 - lon1) * Math.PI) / 180;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos((lat1 * Math.PI) / 180) *
      Math.cos((lat2 * Math.PI) / 180) *
      Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// Delivery assignment mode is controlled from Admin: settings/deliveryAssignment.mode.
// Automatic mode creates a pending_acceptance offer for one currently available partner.
async function autoAssignDeliveryPartner(orderRef, order, orderId) {
  const settingsSnap = await db.collection("settings").doc("deliveryAssignment").get();
  const mode = String(settingsSnap.data()?.mode || "manual").toLowerCase();
  if (mode !== "automatic") return null;

  const current = await orderRef.get();
  const currentData = current.data() || {};
  const currentStatus = String(currentData.status || "").toLowerCase();
  const alreadyAssigned = String(
    currentData.carrierUid || currentData.deliveryPartnerUid || currentData.assignedPartnerId || ""
  ).trim();
  if (alreadyAssigned) return null;
  if (["cancelled", "delivered", "completed", "rejected", "expired"].includes(currentStatus)) return null;

  const pickupLat = Number(
    order.customerLatitude ?? order.pickupLatitude ?? order.customerLat ?? order.pickupLat
  );
  const pickupLng = Number(
    order.customerLongitude ?? order.pickupLongitude ?? order.customerLng ?? order.pickupLng
  );

  let candidates = [];
  const serviceUrl = String(process.env.LOCATION_SERVICE_URL || "").replace(/\\/+$/, "");
  const serviceToken = String(process.env.LOCATION_SERVICE_TOKEN || "");
  if (serviceUrl && serviceToken && Number.isFinite(pickupLat) && Number.isFinite(pickupLng)) {
    const response = await fetch(serviceUrl + "/v1/match", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Location-Service-Token": serviceToken },
      body: JSON.stringify({
        role: "delivery_partner",
        latitude: pickupLat,
        longitude: pickupLng,
        radiusKm: 10,
        limit: 30,
      }),
      signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) throw new Error("H3 delivery matching returned HTTP " + response.status);
    const payload = await response.json();
    const ids = [...new Set((Array.isArray(payload.candidates) ? payload.candidates : [])
      .map((candidate) => String(candidate.uid || "").trim())
      .filter(Boolean))].slice(0, 30);
    if (ids.length) {
      const docs = await db.getAll(...ids.map((uid) => db.collection("deliveryPartners").doc(uid)));
      candidates = docs.filter((doc) => doc.exists);
    }
  } else {
    // Compatibility mode only until the private H3/Redis service is configured.
    const snap = await db.collection("deliveryPartners")
      .where("approvalStatus", "==", "approved")
      .where("shiftStatus", "==", "on_duty")
      .where("status", "==", "online")
      .limit(500)
      .get();
    candidates = snap.docs;
  }

  candidates = candidates.filter((doc) => {
    const p = doc.data() || {};
    return String(p.approvalStatus || "").toLowerCase() === "approved" &&
      String(p.shiftStatus || "").toLowerCase() === "on_duty" &&
      p.locationTrackingActive !== false &&
      p.availableForDeliveries !== false &&
      p.isOnline !== false &&
      !String(p.currentOrderId || "").trim() &&
      !String(p.pendingOrderId || "").trim();
  });

  if (!candidates.length) {
    await orderRef.set({
      assignmentMethod: "automatic",
      assignmentStatus: "waiting_for_partner",
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    return null;
  }

  let chosen = candidates[0];
  let bestDistance = Number.POSITIVE_INFINITY;
  if (Number.isFinite(pickupLat) && Number.isFinite(pickupLng)) {
    for (const doc of candidates) {
      const p = doc.data() || {};
      const lat = Number(p.deliveryLat ?? p.lastLat ?? p.latitude);
      const lng = Number(p.deliveryLng ?? p.lastLng ?? p.longitude);
      if (!Number.isFinite(lat) || !Number.isFinite(lng)) continue;
      const distance = distanceKm(pickupLat, pickupLng, lat, lng);
      if (distance < bestDistance) {
        bestDistance = distance;
        chosen = doc;
      }
    }
  }

  const partnerRef = chosen.ref;
  const partner = chosen.data() || {};
  const partnerUid = chosen.id;
  const partnerName = String(partner.name || partner.displayName || partner.email || "ALLways Delivery Partner");
  const partnerPhone = String(partner.phone || partner.mobileNumber || "");
  const partnerVehicle = String(partner.vehicleType || "bike");

  // Atomic claim: another order cannot claim the same available partner at the same time.
  await db.runTransaction(async (tx) => {
    const latestOrder = await tx.get(orderRef);
    const latestPartner = await tx.get(partnerRef);
    const latestOrderData = latestOrder.data() || {};
    const latestPartnerData = latestPartner.data() || {};
    const assigned = String(
      latestOrderData.carrierUid || latestOrderData.deliveryPartnerUid || latestOrderData.assignedPartnerId || ""
    ).trim();
    const partnerBusy =
      latestPartnerData.availableForDeliveries === false ||
      latestPartnerData.isOnline === false ||
      String(latestPartnerData.currentOrderId || "").trim() ||
      String(latestPartnerData.pendingOrderId || "").trim();

    if (assigned || partnerBusy) throw new Error("AUTO_ASSIGN_RETRY");

    tx.update(orderRef, {
      carrierUid: partnerUid,
      deliveryPartnerUid: partnerUid,
      assignedPartnerId: partnerUid,
      carrierName: partnerName,
      carrierPhone: partnerPhone,
      carrierVehicleType: partnerVehicle,
      carrierAccepted: false,
      assignmentRejected: false,
      assignmentMethod: "automatic",
      assignmentStatus: "pending_acceptance",
      assignedAt: FieldValue.serverTimestamp(),
      status: "pending_acceptance",
      statusNote: "Automatically assigned to an available delivery partner.",
      customerMessage: "A delivery partner has been assigned and is being notified.",
      updatedAt: FieldValue.serverTimestamp(),
    });
    tx.update(partnerRef, {
      pendingOrderId: orderId,
      availableForDeliveries: false,
      // Keep the partner online so the app can display and accept this pending offer.
      dutyStatus: "online",
      updatedAt: FieldValue.serverTimestamp(),
    });
  });

  
return partnerUid;
}

function newConfirmationPin() {
  return String(crypto.randomInt(0, 10000)).padStart(4, "0");
}

function ensureConfirmationPin(data) {
  const existing = String(data?.confirmationPin || "").trim();
  return /^\d{4}$/.test(existing) ? existing : newConfirmationPin();
}

// Order creation, delivery assignment and push notifications are server-side. Deploy these functions on a Firebase plan that supports Cloud Functions.
exports.onAllwaysOrderCreated = onDocumentCreated(
  "orders/{orderId}",
  async (event) => {
    const order = event.data?.data();
    if (!order) return;

    const orderRef = event.data.ref;
    
    // Keep confirmation PINs in a customer-only record, never on the order
    // document that assigned delivery partners must be able to read.
    const customerUid = String(order.customerUid || order.customerId || "").trim();
    const privatePinRef = db.collection("customerPrivatePins").doc("delivery_" + event.params.orderId);
    const privatePinSnap = await privatePinRef.get();
    if (!privatePinSnap.exists && customerUid) {
      const legacyPin = String(order.confirmationPin || "").trim();
      await privatePinRef.set({
        customerUid,
        recordId: event.params.orderId,
        type: "delivery",
        confirmationPin: /^\d{4}$/.test(legacyPin) ? legacyPin : newConfirmationPin(),
        attempts: 0,
        createdAt: FieldValue.serverTimestamp(),
      });
    }
    if (Object.prototype.hasOwnProperty.call(order, "confirmationPin")) {
      await orderRef.update({
        confirmationPin: FieldValue.delete(),
        deliveryPinVerified: false,
        deliveryPinVerifiedAt: null,
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
try {
      const partnerUid = await autoAssignDeliveryPartner(orderRef, order, event.params.orderId);
      if (partnerUid) {
        await sendToUser(
          partnerUid,
          "New delivery assignment",
          "A new ALLways delivery order is waiting for your acceptance.",
          { type: "delivery_assignment", orderId: event.params.orderId },
          "delivery_partner"
        );
      }
    } catch (error) {
      if (String(error?.message || error) !== "AUTO_ASSIGN_RETRY") {
        console.error("Automatic delivery assignment failed:", error);
        await orderRef.set({
          assignmentMethod: "automatic",
          assignmentStatus: "failed",
          assignmentError: String(error?.message || error),
          updatedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
      }
    }
  }
);

// Order updates: partner assignment/acceptance and customer status state remain server-side.
async function settleInventoryReservation(orderId, terminalStatus) {
  const normalized = String(terminalStatus || "").trim().toLowerCase();
  const disposition = normalized === "delivered" || normalized === "completed"
    ? "consumed"
    : (normalized === "cancelled" || normalized === "canceled" ? "released" : "");
  if (!disposition) return;

  const reservationRef = db.collection("inventoryReservations").doc(orderId);
  await db.runTransaction(async (tx) => {
    const reservationSnap = await tx.get(reservationRef);
    if (!reservationSnap.exists) return;
    const reservation = reservationSnap.data() || {};
    if (reservation.status !== "reserved") return;

    const items = Array.isArray(reservation.items) ? reservation.items : [];
    const refs = items.map((item) => db.collection("inventory").doc(String(item.productId || "")));
    const inventorySnaps = await Promise.all(refs.map((ref) => tx.get(ref)));
    const now = FieldValue.serverTimestamp();
    for (let i = 0; i < items.length; i++) {
      const snap = inventorySnaps[i];
      if (!snap.exists) continue;
      const current = snap.data() || {};
      const qty = Math.max(0, Number(items[i].qty || 0));
      const reservedQty = Math.max(0, Number(current.reservedQty || 0));
      const patch = { reservedQty: Math.max(0, reservedQty - qty), updatedAt: now };
      if (disposition === "consumed") {
        patch.stock = Math.max(0, Number(current.stock || 0) - qty);
      }
      tx.update(refs[i], patch);
    }
    tx.update(reservationRef, {
      status: disposition,
      settledAt: now,
      updatedAt: now,
    });
  });
}

exports.onAllwaysOrderUpdated = onDocumentUpdated(
  "orders/{orderId}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after = event.data.after.data() || {};
    const orderId = event.params.orderId;
    const oldStatus = String(before.status || "");
    const newStatus = String(after.status || "");
    const oldPartner = String(before.carrierUid || before.assignedPartnerId || "");
    const newPartner = String(after.carrierUid || after.assignedPartnerId || "");

    if (oldStatus !== newStatus &&
        ["delivered", "completed", "cancelled", "canceled"].includes(newStatus.trim().toLowerCase())) {
      await settleInventoryReservation(orderId, newStatus);
      await db.collection("customerPrivatePins").doc("delivery_" + orderId).delete().catch(() => {});
    }

    if (newPartner && newPartner !== oldPartner) {
      await sendToUser(
        newPartner,
        "New delivery assignment",
        "A new ALLways delivery order is waiting for your acceptance.",
        { type: "delivery_assignment", orderId },
        "delivery_partner"
      );
}

    if ((oldStatus === "pending_acceptance" || oldStatus === "assigned") && newStatus === "Assigned" && newPartner) {
      await db.collection("deliveryPartners").doc(newPartner).set({
        pendingOrderId: null,
        currentOrderId: orderId,
        availableForDeliveries: false,
        dutyStatus: "on_delivery",
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });

      
}

    if ((oldStatus === "pending_acceptance" || oldStatus === "assigned") && newStatus === "unassigned" && oldPartner) {
      
await db.collection("deliveryPartners").doc(oldPartner).set({
        pendingOrderId: null,
        currentOrderId: null,
        availableForDeliveries: true,
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
    }

    if (oldPartner && (newStatus === "Delivered" || newStatus === "Cancelled" || newStatus === "Completed")) {
      await db.collection("deliveryPartners").doc(oldPartner).set({
        pendingOrderId: null,
        currentOrderId: null,
        availableForDeliveries: true,
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
    }

    if (oldStatus !== newStatus) {
      const customerUid = String(after.customerId || after.customerUid || "").trim();
      if (customerUid) {
        const normalized = newStatus.toLowerCase().replace(/\s+/g, "_");
        await sendToUser(
          customerUid,
          "ALLways order update",
          String(after.customerMessage || after.statusNote || ("Order status: " + newStatus)),
          { type: "order_status", orderId, status: normalized },
          "customer"
        );
      }
      if (newPartner) {
        await sendToUser(
          newPartner,
          "Delivery status updated",
          String(after.customerMessage || after.statusNote || ("Order status: " + newStatus)),
          { type: "delivery_status", orderId, status: newStatus },
          "delivery_partner"
        );
      }
    }
  }
);

async function rideMatchingRadiusKm() {
  try {
    const snap = await db.collection("settings").doc("ride").get();
    const value = Number(snap.data()?.matchingRadiusKm);
    if (Number.isFinite(value) && value > 0) return Math.min(value, 50);
  } catch (_) {}
  return 7;
}

// New ride requests are pushed directly to nearby eligible carrier devices.
exports.onAutoRideRequestCreated = onDocumentCreated(
  "autoRideRequests/{requestId}",
  async (event) => {
    const ride = event.data?.data();
    if (!ride || String(ride.status || "").toLowerCase() !== "searching") return;
    const requestRef = event.data.ref;
    const requestId = event.params.requestId;
    const rideType = String(ride.rideType || "bike").toLowerCase();
    const pickupLat = Number(ride.pickupLatitude ?? ride.pickupLat);
    const pickupLng = Number(ride.pickupLongitude ?? ride.pickupLng);
    if (!Number.isFinite(pickupLat) || !Number.isFinite(pickupLng)) return;

    // Migration compatibility: move a legacy PIN out of the readable ride
    // document. New clients create the customer-private PIN in the booking batch.
    const customerUid = String(ride.customerUid || ride.customerId || "").trim();
    const privatePinRef = db.collection("customerPrivatePins").doc("ride_" + requestId);
    const privatePinSnap = await privatePinRef.get();
    if (!privatePinSnap.exists && customerUid) {
      const legacyPin = String(ride.confirmationPin || "").trim();
      await privatePinRef.set({
        customerUid,
        recordId: requestId,
        type: "ride",
        confirmationPin: /^\d{4}$/.test(legacyPin) ? legacyPin : newConfirmationPin(),
        attempts: 0,
        createdAt: FieldValue.serverTimestamp(),
      });
    }
    if (Object.prototype.hasOwnProperty.call(ride, "confirmationPin")) {
      await requestRef.update({
        confirmationPin: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }

    const createdMs = ride.createdAt?.toMillis ? ride.createdAt.toMillis() : Date.now();
    const expiresAtMs = ride.expiresAt?.toMillis ? ride.expiresAt.toMillis() : createdMs + 30 * 60 * 1000;
    if (!ride.expiresAt) {
      await requestRef.set({ expiresAt: new Date(expiresAtMs), updatedAt: FieldValue.serverTimestamp() }, { merge: true });
    }
    if (Date.now() >= expiresAtMs) {
      await requestRef.set({ status: "expired", expiredAt: FieldValue.serverTimestamp(), customerActive: false, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
      return;
    }

    const matchingRadiusKm = await rideMatchingRadiusKm();
    let partners = [];
    const serviceUrl = String(process.env.LOCATION_SERVICE_URL || "").replace(/\/+$/, "");
    const serviceToken = String(process.env.LOCATION_SERVICE_TOKEN || "");
    if (serviceUrl && serviceToken) {
      // When configured, the internal H3/Redis index is authoritative for the
      // candidate set. Fail closed on service errors rather than scanning all drivers.
      const response = await fetch(serviceUrl + "/v1/match", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Location-Service-Token": serviceToken },
        body: JSON.stringify({
          role: "carrier",
          latitude: pickupLat,
          longitude: pickupLng,
          radiusKm: matchingRadiusKm,
          vehicleType: rideType,
          limit: 50,
        }),
        signal: AbortSignal.timeout(5000),
      });
      if (!response.ok) throw new Error("H3 matching returned HTTP " + response.status);
      const payload = await response.json();
      const ids = [...new Set((Array.isArray(payload.candidates) ? payload.candidates : [])
        .map((candidate) => String(candidate.uid || "").trim())
        .filter(Boolean))].slice(0, 50);
      if (ids.length) {
        const docs = await db.getAll(...ids.map((uid) => db.collection("ridePartners").doc(uid)));
        partners = docs.filter((doc) => doc.exists);
      }
    } else {
      // Conservative compatibility mode for development before Redis is deployed.
      const snap = await db.collection("ridePartners")
        .where("shiftStatus", "==", "on_duty")
        .where("status", "==", "online")
        .limit(500)
        .get();
      partners = snap.docs;
    }

    const offerExpiresAt = new Date(Math.min(expiresAtMs, Date.now() + 120000));
    let offered = 0;
    for (const partner of partners) {
      const p = partner.data() || {};
      if (String(p.approvalStatus || "").toLowerCase() !== "approved") continue;
      if (String(p.shiftStatus || "").toLowerCase() !== "on_duty" || p.locationTrackingActive === false) continue;
      if (String(p.activeRideId || "").trim()) continue;
      if (p.availableForRides === false || p.isOnline === false) continue;

      const rawType = String(p.vehicleType || "bike").toLowerCase();
      const normalizedType = ["two_wheeler", "motorcycle", "scooter"].includes(rawType)
        ? "bike"
        : (["cab", "sedan", "hatchback"].includes(rawType) ? "car" : rawType);
      if (normalizedType !== rideType) continue;

      if (!serviceUrl) {
        const pLat = Number(p.carrierLat ?? p.latitude);
        const pLng = Number(p.carrierLng ?? p.longitude);
        if (!Number.isFinite(pLat) || !Number.isFinite(pLng)) continue;
        if (distanceKm(pickupLat, pickupLng, pLat, pLng) > matchingRadiusKm) continue;
      }

      const offerRef = db.collection("rideOffers").doc(partner.id).collection("requests").doc(requestId);
      await offerRef.set({
        rideId: requestId,
        status: "searching",
        rejected: false,
        rideType,
        pickupLatitude: pickupLat,
        pickupLongitude: pickupLng,
        pickupAddress: String(ride.pickupAddress || ""),
        pickupPincode: String(ride.pickupPincode || ""),
        destinationAddress: String(ride.destinationAddress || ride.destination || ""),
        destinationLatitude: Number(ride.destinationLatitude) || null,
        destinationLongitude: Number(ride.destinationLongitude) || null,
        estimatedFare: Number(ride.estimatedFare || ride.fare || 0),
        distanceKm: Number(ride.distanceKm || 0),
        etaMinutes: Number(ride.etaMinutes || 0),
        offeredAt: FieldValue.serverTimestamp(),
        offerExpiresAt,
      }, { merge: true });

      await sendToUser(
        partner.id,
        "New ride request",
        "A nearby " + rideType.toUpperCase() + " ride is waiting. Open ALLways to review it.",
        { type: "ride_request", requestId, rideType },
        "carrier"
      );
      offered++;
    }

    await requestRef.set({
      matchingAttemptedAt: FieldValue.serverTimestamp(),
      matchingCandidateCount: offered,
    }, { merge: true });
  }
);

// Expire customer ride searches server-side so the request cannot remain searchable forever.
exports.expireSearchingRides = onSchedule("every 5 minutes", async () => {
  const snap = await db.collection("autoRideRequests").where("status", "==", "searching").limit(500).get();
  const now = Date.now();
  for (const doc of snap.docs) {
    const ride = doc.data() || {};
    const createdMs = ride.createdAt?.toMillis ? ride.createdAt.toMillis() : now;
    const expiresMs = ride.expiresAt?.toMillis ? ride.expiresAt.toMillis() : createdMs + 30 * 60 * 1000;
    if (now < expiresMs) {
      if (!ride.expiresAt) await doc.ref.set({ expiresAt: new Date(expiresMs) }, { merge: true });
      continue;
    }
    await doc.ref.set({
      status: "expired",
      customerActive: false,
      expiredAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    const customerUid = String(ride.customerUid || ride.customerId || "").trim();
    if (customerUid) {
      await sendToUser(customerUid, "Ride search expired", "We could not find a ride nearby within 30 minutes. Try again or change your pickup location.", { type: "ride_status", requestId: doc.id, status: "expired" }, "customer");
    }
  }
});

// Ride state changes also notify the relevant customer/partner devices.
exports.onAutoRideRequestUpdated = onDocumentUpdated(
  "autoRideRequests/{requestId}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after = event.data.after.data() || {};
    const oldStatus = String(before.status || "").toLowerCase();
    const newStatus = String(after.status || "").toLowerCase();
    if (oldStatus === newStatus) return;

    const requestId = event.params.requestId;
    const terminalStatuses = new Set(["cancelled", "completed", "expired", "rejected"]);
    if (newStatus === "accepted" || terminalStatuses.has(newStatus)) {
      const offers = await db.collectionGroup("requests")
        .where("rideId", "==", requestId)
        .limit(100)
        .get();
      const batch = db.batch();
      let writes = 0;
      const winningUid = String(after.driverUid || after.carrierUid || "").trim();
      for (const offerDoc of offers.docs) {
        const offer = offerDoc.data() || {};
        const ownerUid = offerDoc.ref.parent.parent?.id || "";
        const isWinner = newStatus === "accepted" && ownerUid === winningUid;
        const nextStatus = isWinner ? "accepted" : "expired";
        if (String(offer.status || "").toLowerCase() !== nextStatus) {
          batch.set(offerDoc.ref, {
            status: nextStatus,
            resolvedAt: FieldValue.serverTimestamp(),
          }, { merge: true });
          writes++;
        }
      }
      if (writes) await batch.commit();
      if (terminalStatuses.has(newStatus)) {
        await db.collection("customerPrivatePins").doc("ride_" + requestId).delete().catch(() => {});
      }
    }

    const customerUid = String(after.customerUid || after.customerId || "").trim();
    if (!customerUid) return;

    if (newStatus === "accepted") {
      await sendToUser(customerUid, "Ride accepted", "Your ALLways ride has been accepted by a carrier.", { type: "ride_status", requestId: event.params.requestId, status: newStatus }, "customer");
      const carrierUid = String(after.driverUid || after.carrierUid || "").trim();
      if (carrierUid) await sendToUser(carrierUid, "Ride accepted", "You have accepted this ALLways ride.", { type: "ride_status", requestId: event.params.requestId, status: newStatus }, "carrier");
    } else if (newStatus === "rejected") {
      await sendToUser(customerUid, "Ride update", "The carrier could not accept this ride. ALLways is checking for another available carrier.", { type: "ride_status", requestId: event.params.requestId, status: newStatus }, "customer");
    } else if (newStatus === "cancelled") {
      const carrierUid = String(after.driverUid || after.carrierUid || "").trim();
      if (carrierUid) await sendToUser(carrierUid, "Ride cancelled", "The customer cancelled the ALLways ride.", { type: "ride_status", requestId: event.params.requestId, status: newStatus }, "carrier");
    } else if (newStatus === "completed") {
      await sendToUser(customerUid, "Ride completed", "Your ALLways ride has been completed.", { type: "ride_status", requestId: event.params.requestId, status: newStatus }, "customer");
    }
  }
);


// Secure confirmation PIN verification. Only the assigned carrier/delivery partner can
// advance the protected state, and the PIN itself is never returned by this function.
exports.verifyConfirmationPin = onCall({ region: "asia-south1", maxInstances: 100 }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in is required.");

  const type = String(request.data?.type || "").toLowerCase();
  const id = String(request.data?.id || "").trim();
  const pin = String(request.data?.pin || "").trim();
  if (!["ride", "delivery"].includes(type) || !id || !/^\d{4}$/.test(pin)) {
    throw new HttpsError("invalid-argument", "A valid 4-digit confirmation PIN is required.");
  }

  const collection = type === "ride" ? "autoRideRequests" : "orders";
  const ref = db.collection(collection).doc(id);
  const pinRef = db.collection("customerPrivatePins").doc(type + "_" + id);
  const result = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const pinSnap = await tx.get(pinRef);
    if (!snap.exists) throw new HttpsError("not-found", "The request could not be found.");
    if (!pinSnap.exists) throw new HttpsError("failed-precondition", "The customer confirmation PIN is unavailable. Contact support.");
    const data = snap.data() || {};
    const pinData = pinSnap.data() || {};
    const assignedUid = type === "ride"
      ? String(data.driverUid || data.carrierUid || "").trim()
      : String(data.carrierUid || data.deliveryPartnerUid || data.assignedPartnerId || "").trim();
    if (assignedUid !== uid) throw new HttpsError("permission-denied", "You are not assigned to this request.");

    const nowMs = Date.now();
    const lockedUntil = pinData.lockedUntil?.toMillis
      ? pinData.lockedUntil.toMillis()
      : (pinData.lockedUntil instanceof Date ? pinData.lockedUntil.getTime() : 0);
    if (lockedUntil > nowMs) throw new HttpsError("resource-exhausted", "Too many incorrect PIN attempts. Wait before trying again.");

    const expected = String(pinData.confirmationPin || "").trim();
    if (!expected || expected !== pin) {
      const attempts = lockedUntil > 0 ? 1 : Math.max(0, Number(pinData.attempts || 0)) + 1;
      const update = {
        attempts,
        lastAttemptAt: FieldValue.serverTimestamp(),
      };
      if (attempts >= 5) {
        update.lockedUntil = new Date(nowMs + 15 * 60 * 1000);
        update.attempts = 0;
      } else {
        update.lockedUntil = FieldValue.delete();
      }
      tx.update(pinRef, update);
      return { wrongPin: true };
    }

    if (type === "ride") {
      const status = String(data.status || "").toLowerCase();
      if (!["accepted", "arrived"].includes(status)) {
        if (status === "started") return { verified: true, alreadyStarted: true };
        throw new HttpsError("failed-precondition", "The ride is not ready to start.");
      }
      tx.update(ref, {
        status: "started",
        ridePinVerified: true,
        ridePinVerifiedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    } else {
      const status = String(data.status || "").trim().toLowerCase();
      // A partner may explicitly mark arrival before opening PIN verification.
      // Both states are eligible, but a completed delivery remains idempotent.
      if (!["out for delivery", "arrived"].includes(status)) {
        if (status === "delivered") return { verified: true, alreadyDelivered: true };
        throw new HttpsError("failed-precondition", "The delivery is not ready to complete.");
      }

      // Payment status is server-owned. For COD, require an explicit partner
      // confirmation before the delivery can be finalized. Online payments
      // remain blocked at checkout until a verified provider is integrated.
      const paymentMethod = String(data.paymentMethod || "COD").trim().toUpperCase();
      if (paymentMethod === "COD" && request.data?.cashCollected !== true) {
        throw new HttpsError("failed-precondition", "Confirm cash collection before completing this COD delivery.");
      }
      if (paymentMethod !== "COD" && String(data.paymentStatus || "").trim().toLowerCase() !== "paid") {
        throw new HttpsError("failed-precondition", "The order payment has not been confirmed by the payment provider.");
      }

      const completedAt = FieldValue.serverTimestamp();
      tx.update(ref, {
        status: "Delivered",
        deliveryPinVerified: true,
        deliveryPinVerifiedAt: completedAt,
        updatedAt: completedAt,
        ...(paymentMethod === "COD" ? {
          cashCollected: true,
          cashCollectedAt: completedAt,
          cashCollectedBy: uid,
          paymentStatus: "cash_collected",
        } : {}),
        carrierLat: FieldValue.delete(),
        carrierLng: FieldValue.delete(),
        carrierLocationUpdatedAt: FieldValue.delete(),
      });
    }
    // The PIN is single-use. Deleting it also limits retention of this secret.
    tx.delete(pinRef);
    return { verified: true };
  });

  if (result?.wrongPin) {
    throw new HttpsError("permission-denied", "Incorrect confirmation PIN.");
  }
  return result;
});

// Complete a ride only after the assigned driver has verified the passenger PIN.
exports.completeRide = onCall({ region: "asia-south1" }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in is required.");

  const rideId = String(request.data?.rideId || "").trim();
  if (!rideId) throw new HttpsError("invalid-argument", "A ride ID is required.");

  const rideRef = db.collection("autoRideRequests").doc(rideId);
  const partnerRef = db.collection("ridePartners").doc(uid);

  return db.runTransaction(async (tx) => {
    const rideSnap = await tx.get(rideRef);
    if (!rideSnap.exists) throw new HttpsError("not-found", "The ride could not be found.");

    const ride = rideSnap.data() || {};
    const assignedUid = String(ride.driverUid || ride.carrierUid || "").trim();
    if (assignedUid !== uid) {
      throw new HttpsError("permission-denied", "You are not assigned to this ride.");
    }

    const status = String(ride.status || "").toLowerCase();
    if (status === "completed") return { completed: true, alreadyCompleted: true };
    if (status !== "started" || ride.ridePinVerified !== true) {
      throw new HttpsError("failed-precondition", "Verify the passenger PIN and start the ride before completing it.");
    }

    tx.update(rideRef, {
      status: "completed",
      completedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    tx.set(partnerRef, {
      status: "available",
      availableForRides: true,
      activeRideId: null,
      statusUpdatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    return { completed: true };
  });
});

// Partner registration and approval changes notify the relevant partner.
exports.onRidePartnerCreated = onDocumentCreated(
  "ridePartners/{uid}",
  async (event) => {
    const data = event.data?.data() || {};
    
}
);

exports.onDeliveryPartnerCreated = onDocumentCreated(
  "deliveryPartners/{uid}",
  async (event) => {
    
}
);

exports.onRidePartnerUpdated = onDocumentUpdated(
  "ridePartners/{uid}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after = event.data.after.data() || {};
    if (String(before.approvalStatus || "") === String(after.approvalStatus || "")) return;
    const status = String(after.approvalStatus || "");
    if (!status) return;
    await sendToUser(
      event.params.uid,
      "Carrier application update",
      status.toLowerCase() === "approved" ? "Your ALLways Carrier account is approved." : "Your ALLways Carrier application status is " + status + ".",
      { type: "approval", status },
      "carrier"
    );
}
);

exports.onDeliveryPartnerUpdated = onDocumentUpdated(
  "deliveryPartners/{uid}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after = event.data.after.data() || {};
    if (String(before.approvalStatus || "") === String(after.approvalStatus || "")) return;
    const status = String(after.approvalStatus || "");
    if (!status) return;
    await sendToUser(
      event.params.uid,
      "Delivery partner application update",
      status.toLowerCase() === "approved" ? "Your ALLways Delivery Partner account is approved." : "Your ALLways Delivery Partner application status is " + status + ".",
      { type: "approval", status },
      "delivery_partner"
    );
}
);

exports.onNotificationBroadcastCreated = onDocumentCreated(
  "notificationBroadcasts/{notificationId}",
  async (event) => {
    const ref = event.data?.ref;
    if (!ref) return;

    const latest = await ref.get();
    const data = latest.data() || event.data.data() || {};
    if (String(data.status || "").toLowerCase() === "sent") return;

    const title = String(data.title || "ALLways").trim();
    const body = String(data.body || data.message || "").trim();
    const topic = String(data.topic || data.targetAudience || "all_users").trim().toLowerCase();
    const allowed = new Set(["all_users", "customers", "admins", "carriers", "delivery_partners"]);
    const safeTopic = allowed.has(topic) ? topic : "all_users";

    if (!body) {
      await ref.set({
        status: "failed",
        error: "Notification message is empty.",
        failedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      return;
    }

    try {
      await ref.set({
        status: "sending",
        attemptedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
        error: FieldValue.delete(),
      }, { merge: true });
      const messageId = await sendToTopic(safeTopic, title, body, {
        type: "broadcast",
        notificationId: event.params.notificationId,
      });
      await ref.set({
        status: "sent",
        sentTopic: safeTopic,
        fcmMessageId: messageId,
        sentAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
        error: FieldValue.delete(),
      }, { merge: true });
    } catch (error) {
      const message = String(error?.message || error || "Unknown FCM error").slice(0, 800);
      console.error("ALLways broadcast notification failed:", message);
      await ref.set({
        status: "failed",
        error: message,
        failedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
    }
  }
);

exports.onAllwaysAnnouncementCreated = onDocumentCreated(
  "announcements/{announcementId}",
  async (event) => {
    const ref = event.data?.ref;
    if (!ref) return;
    const latest = await ref.get();
    const announcement = latest.data() || event.data.data() || {};
    if (String(announcement.status || "").toLowerCase() === "sent") return;

    const title = String(announcement.title || "ALLways").trim();
    const body = String(announcement.body || "").trim();
    const rawAudience = String(
      announcement.topic || announcement.targetAudience || "all_users"
    ).trim().toLowerCase();
    const allowedTopics = new Set([
      "all_users",
      "customers",
      "admins",
      "carriers",
      "delivery_partners",
    ]);
    const topic = allowedTopics.has(rawAudience) ? rawAudience : "all_users";

    if (!body) {
      await ref.set({
        status: "failed",
        error: "Announcement message is empty.",
        failedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      return;
    }

    try {
      await ref.set({
        status: "sending",
        attemptedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
        error: FieldValue.delete(),
      }, { merge: true });
      const messageId = await sendToTopic(topic, title, body, {
        type: "announcement",
        announcementId: event.params.announcementId,
      });
      await ref.set({
        status: "sent",
        sentAt: FieldValue.serverTimestamp(),
        sentTopic: topic,
        fcmMessageId: messageId,
        updatedAt: FieldValue.serverTimestamp(),
        error: FieldValue.delete(),
      }, { merge: true });
    } catch (error) {
      const message = String(error?.message || error || "Unknown FCM error").slice(0, 800);
      console.error("ALLways announcement notification failed:", message);
      await ref.set({
        status: "failed",
        error: message,
        failedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
    }
  }
);


exports.onVehicleBookingCreated = onDocumentCreated(
  "vehicleBookings/{bookingId}",
  async (event) => {
    const booking=event.data?.data();
    if(!booking)return;
    const ownerUid=String(booking.ownerUid||"").trim();
    if(!ownerUid)return;
    
}
);

exports.onVehicleBookingUpdated = onDocumentUpdated(
  "vehicleBookings/{bookingId}",
  async (event) => {
    const before=event.data.before.data()||{};
    const after=event.data.after.data()||{};
    if(String(before.status||"").toLowerCase()===String(after.status||"").toLowerCase())return;
    const uid=String(after.customerUid||"").trim();
    if(!uid)return;
    const status=String(after.status||"");
    await sendToUser(
      uid,
      "Vehicle booking update",
      "Your vehicle booking status is " + status + ".",
      { type: "vehicle_booking_status", bookingId: event.params.bookingId, status },
      "customer"
    );
}
);

// Automatic Google Sheets -> Firestore catalog synchronization.

const CATALOG_SYNC_ENDPOINT = "https://script.google.com/macros/s/AKfycbxnmGS7Q6t7PpPWiT50V87JmA0Qbh2tSi1UKLFzN28dQpybjw7vvCufnryi-qpTnq0b0IA/exec";
function catalogValue(row, headers, name, fallback = "") {
  if (row && !Array.isArray(row) && typeof row === "object") {
    const key = Object.keys(row).find(k => String(k).trim().toLowerCase() === name.toLowerCase());
    return key ? row[key] : fallback;
  }
  if (!Array.isArray(row) || !Array.isArray(headers)) return fallback;
  const index = headers.findIndex(h => String(h).trim().toLowerCase() === name.toLowerCase());
  return index >= 0 ? row[index] : fallback;
}
function catalogBool(value, fallback = true) {
  if (typeof value === "boolean") return value;
  const v = String(value ?? "").trim().toLowerCase();
  if (["true", "1", "yes", "available", "active", "in stock"].includes(v)) return true;
  if (["false", "0", "no", "unavailable", "inactive", "out of stock"].includes(v)) return false;
  return fallback;
}
function catalogNumber(value, fallback = 0) {
  const n = Number(String(value ?? "").replace(/,/g, "").trim());
  return Number.isFinite(n) ? n : fallback;
}
exports.syncCatalogFromGoogleSheet = onSchedule(
  { schedule: "every 5 minutes", timeZone: "Asia/Kolkata", region: "asia-south1" },
  async () => {
    // 230502 is the first explicitly serviceable pilot pincode.
    await db.collection("serviceableZones").doc("230502").set({
      pincode: "230502",
      status: "serviceable",
      label: "Serviceable",
      updatedAt: FieldValue.serverTimestamp(),
      source: "allways_pilot",
    }, { merge: true });

    const response = await fetch(CATALOG_SYNC_ENDPOINT, { redirect: "follow" });
    if (!response.ok) throw new Error("Catalog Apps Script returned HTTP " + response.status);
    const payload = await response.json();
    if (!payload || payload.success !== true) throw new Error("Catalog Apps Script did not return success:true");
    const headers = Array.isArray(payload.headers) ? payload.headers : [];
    const rows = Array.isArray(payload.rows) ? payload.rows : [];
    let written = 0;
    for (let i = 0; i < rows.length; i += 400) {
      const batch = db.batch();
      for (const row of rows.slice(i, i + 400)) {
        const rawId = catalogValue(row, headers, "ID", "");
        const name = String(catalogValue(row, headers, "Product Name", "")).trim();
        if (!name) continue;
        const fallbackId = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
        const id = String(rawId || fallbackId).trim();
        if (!id) continue;
        const product = {
          id,
          name,
          category: String(catalogValue(row, headers, "Category", "")).trim(),
          emoji: String(catalogValue(row, headers, "Emoji", "")).trim(),
          price: catalogNumber(catalogValue(row, headers, "Price", 0)),
          stock: catalogNumber(catalogValue(row, headers, "Stock", 0)),
          available: catalogBool(catalogValue(row, headers, "Available", true), true),
          maxQty: catalogNumber(catalogValue(row, headers, "Max Qty", 10), 10),
          imageUrl: String(catalogValue(row, headers, "Image URL", "")).trim(),
          updatedAt: FieldValue.serverTimestamp(),
          source: "google_sheets",
        };
        batch.set(db.collection("products").doc(id), product, { merge: true });
        batch.set(db.collection("inventory").doc(id), {
          id, productId: id, name, category: product.category, price: product.price,
          stock: product.stock, available: product.available, maxQty: product.maxQty,
          imageUrl: product.imageUrl, updatedAt: FieldValue.serverTimestamp(), source: "google_sheets",
        }, { merge: true });
        written++;
      }
      await batch.commit();
    }
    await db.collection("serviceableZones").doc("230502").set({
      pincode: "230502",
      status: "serviceable",
      label: "Pratapgarh pilot zone",
      updatedAt: FieldValue.serverTimestamp(),
      source: "ALLways pilot configuration",
    }, { merge: true });
    await db.collection("settings").doc("catalogSync").set({
      endpoint: CATALOG_SYNC_ENDPOINT, source: "google_sheets", automatic: true,
      schedule: "every 5 minutes", lastSyncAt: FieldValue.serverTimestamp(),
      lastRowCount: rows.length, lastWrittenCount: written, status: "success",
    }, { merge: true });
    console.log("Automatic catalog sync completed:", { rows: rows.length, written });
  }
);

// Notify customers when an admin replies or changes a support ticket.
exports.onSupportTicketUpdated = onDocumentUpdated("supportTickets/{ticketId}", async (event) => {
  const before = event.data.before.data() || {};
  const after = event.data.after.data() || {};
  const customerUid = String(after.customerUid || after.userUid || after.requesterId || "").trim();
  if (!customerUid) return;
  const replyChanged = String(before.adminReply || "") !== String(after.adminReply || "");
  const statusChanged = String(before.status || "") !== String(after.status || "");
  if (!replyChanged && !statusChanged) return;
  const status = String(after.status || "open");
  const title = replyChanged ? "ALLways Support replied" : "Support ticket updated";
  const body = replyChanged ? String(after.adminReply || "You have a new support reply.") : "Your ALLways support ticket is now " + status.replaceAll("_", " ") + ".";
  await sendToUser(customerUid, title, body, { type: "support_update", ticketId: event.params.ticketId, status }, "customer");
});
