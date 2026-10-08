const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const crypto = require("crypto");

initializeApp();

const db = getFirestore();

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
  const root = await ref.get();
  const rootToken = String(root.data()?.token || "").trim();
  if (rootToken) tokens.add(rootToken);
  const snap = await ref.collection("tokens").get();
  for (const doc of snap.docs) {
    const token = String(doc.data()?.token || doc.id || "").trim();
    if (token) tokens.add(token);
  }
  return [...tokens];
}

async function sendToUser(uid, title, body, data = {}, role = "") {
  const tokens = await tokensForUser(uid);
  if (!tokens.length) return { successCount: 0, failureCount: 0 };
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
    for (const token of invalid) batch.delete(ref.collection("tokens").doc(token));
    await batch.commit();
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

  const snap = await db.collection("deliveryPartners")
    .where("approvalStatus", "==", "approved")
    .where("status", "==", "online")
    .get();

  const candidates = snap.docs.filter((doc) => {
    const p = doc.data() || {};
    return p.availableForDeliveries !== false &&
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
    
    if (!/^\d{4}$/.test(String(order.confirmationPin || ""))) {
      await orderRef.set({
        confirmationPin: newConfirmationPin(),
        deliveryPinVerified: false,
        deliveryPinVerifiedAt: null,
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
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

    if (!/^\d{4}$/.test(String(after.confirmationPin || "")) &&
        ["out for delivery", "delivered"].includes(newStatus.toLowerCase())) {
      await event.data.after.ref.set({
        confirmationPin: newConfirmationPin(),
        deliveryPinVerified: false,
        deliveryPinVerifiedAt: null,
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
      return;
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
    if (!/^\d{4}$/.test(String(ride.confirmationPin || ""))) {
      await event.data.ref.set({
        confirmationPin: newConfirmationPin(),
        ridePinVerified: false,
        ridePinVerifiedAt: null,
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
    }

    const rideType = String(ride.rideType || "bike").toLowerCase();
    const createdMs = ride.createdAt?.toMillis ? ride.createdAt.toMillis() : Date.now();
    const expiresAtMs = ride.expiresAt?.toMillis ? ride.expiresAt.toMillis() : createdMs + 30 * 60 * 1000;
    if (!ride.expiresAt) {
      await event.data.ref.set({ expiresAt: new Date(expiresAtMs), updatedAt: FieldValue.serverTimestamp() }, { merge: true });
    }
    if (Date.now() >= expiresAtMs) {
      await event.data.ref.set({ status: "expired", expiredAt: FieldValue.serverTimestamp(), customerActive: false, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
      return;
    }
    const pickupLat = Number(ride.pickupLatitude);
    const pickupLng = Number(ride.pickupLongitude);
    if (!Number.isFinite(pickupLat) || !Number.isFinite(pickupLng)) return;

    const snap = await db.collection("ridePartners")
      .where("status", "==", "online")
      .get();
    const matchingRadiusKm = await rideMatchingRadiusKm();
    const offerExpiresAt = Date.now() + 30000;

    for (const partner of snap.docs) {
      const p = partner.data() || {};
      const type = String(p.vehicleType || "bike").toLowerCase();
      const normalizedType = type === "two_wheeler" || type === "motorcycle" || type === "scooter"
        ? "bike"
        : (type === "cab" || type === "sedan" || type === "hatchback" ? "car" : type);
      if (normalizedType !== rideType) continue;
      if (String(p.approvalStatus || "approved").toLowerCase() !== "approved") continue;
      if (String(p.activeRideId || "").trim()) continue;
      if (p.availableForRides === false || p.isOnline === false) continue;

      const pLat = Number(p.carrierLat ?? p.latitude);
      const pLng = Number(p.carrierLng ?? p.longitude);
      if (!Number.isFinite(pLat) || !Number.isFinite(pLng)) continue;

      const distance = distanceKm(pickupLat, pickupLng, pLat, pLng);
      if (distance > matchingRadiusKm) continue;

      await sendToUser(
        partner.id,
        "New ride request",
        "A nearby " + rideType.toUpperCase() + " ride is waiting. Open ALLways to accept it.",
        { type: "ride_request", requestId: event.params.requestId, rideType },
        "carrier"
      );
}
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

    if (!/^\d{4}$/.test(String(after.confirmationPin || "")) &&
        ["accepted", "arrived", "started"].includes(newStatus)) {
      await event.data.after.ref.set({
        confirmationPin: newConfirmationPin(),
        ridePinVerified: false,
        ridePinVerifiedAt: null,
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
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
exports.verifyConfirmationPin = onCall(async (request) => {
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

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError("not-found", "The request could not be found.");

    const data = snap.data() || {};
    const assignedUid = type === "ride"
      ? String(data.driverUid || data.carrierUid || "").trim()
      : String(data.carrierUid || data.deliveryPartnerUid || data.assignedPartnerId || "").trim();

    if (assignedUid !== uid) {
      throw new HttpsError("permission-denied", "You are not assigned to this request.");
    }

    const expected = String(data.confirmationPin || "").trim();
    if (!expected || expected !== pin) {
      throw new HttpsError("permission-denied", "Incorrect confirmation PIN.");
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
      const status = String(data.status || "").toLowerCase();
      if (status !== "out for delivery") {
        if (status === "delivered") return { verified: true, alreadyDelivered: true };
        throw new HttpsError("failed-precondition", "The delivery is not ready to complete.");
      }
      tx.update(ref, {
        status: "Delivered",
        deliveryPinVerified: true,
        deliveryPinVerifiedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }

    return { verified: true };
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
    const data = event.data.data() || {};
    const title = String(data.title || "ALLways");
    const body = String(data.body || data.message || "");
    const topic = String(data.topic || data.targetAudience || "all_users").toLowerCase();
    if (!body) return;
    const allowed = new Set(["all_users", "customers", "admins", "carriers", "delivery_partners"]);
    const safeTopic = allowed.has(topic) ? topic : "all_users";
    await sendToTopic(safeTopic, title, body, { type: "broadcast", notificationId: event.params.notificationId });
    await ref.set({
      status: "sent",
      sentTopic: safeTopic,
      sentAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  }
);

exports.onAllwaysAnnouncementCreated = onDocumentCreated(
  "announcements/{announcementId}",
  async (event) => {
    const announcement = event.data?.data();
    if (!announcement) return;

    const title = String(announcement.title || "ALLways");
    const body = String(announcement.body || "");
    if (!body) return;

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

    await sendToTopic(topic, title, body, { type: "announcement", announcementId: event.params.announcementId });
    await event.data.ref.set(
      {
        status: "sent",
        sentAt: FieldValue.serverTimestamp(),
        sentTopic: topic,
      },
      { merge: true }
    );
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
const { onSchedule } = require("firebase-functions/v2/scheduler");
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
