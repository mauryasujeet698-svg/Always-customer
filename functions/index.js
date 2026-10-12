const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue, FieldPath } = require("firebase-admin/firestore");
const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");
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
    // Token document IDs may not equal the underlying FCM token value.
    // Compare stored token fields, remove stale devices and never log token strings.
    const invalidTokens = new Set(invalid);
    const tokenRef = db.collection("fcmTokens").doc(uid);
    const tokenDocs = await tokenRef.collection("tokens").get();
    const batch = db.batch();
    for (const tokenDoc of tokenDocs.docs) {
      const storedToken = String(tokenDoc.data()?.token || tokenDoc.id || "").trim();
      if (invalidTokens.has(storedToken)) batch.delete(tokenDoc.ref);
    }
    const root = await tokenRef.get();
    const rootToken = String(root.data()?.token || "").trim();
    if (invalidTokens.has(rootToken)) {
      batch.set(tokenRef, {
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

// Accept delivery assignments through a trusted callable instead of allowing
// an unassigned partner client to claim an order directly.
exports.acceptDeliveryOrder = onCall({ region: "asia-south1" }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in is required.");

  const orderId = String(request.data?.orderId || "").trim();
  if (!orderId) throw new HttpsError("invalid-argument", "A valid order ID is required.");

  const orderRef = db.collection("orders").doc(orderId);
  const partnerRef = db.collection("deliveryPartners").doc(uid);

  return db.runTransaction(async (tx) => {
    const orderSnap = await tx.get(orderRef);
    const partnerSnap = await tx.get(partnerRef);
    if (!orderSnap.exists) throw new HttpsError("not-found", "This delivery order could not be found.");
    if (!partnerSnap.exists) throw new HttpsError("failed-precondition", "Complete your delivery partner profile first.");

    const order = orderSnap.data() || {};
    const partner = partnerSnap.data() || {};
    const status = String(order.status || "").trim().toLowerCase();
    const assignedUid = String(
      order.carrierUid || order.deliveryPartnerUid || order.assignedPartnerId || ""
    ).trim();
    const approvedStatus = String(partner.approvalStatus || "").trim().toLowerCase();
    if (approvedStatus !== "approved") {
      throw new HttpsError("permission-denied", "Admin approval is required before accepting deliveries.");
    }

    if (assignedUid && assignedUid !== uid) {
      throw new HttpsError("already-exists", "This order has already been assigned to another partner.");
    }

    const currentOrderId = String(partner.currentOrderId || "").trim();
    const pendingOrderId = String(partner.pendingOrderId || "").trim();
    if ((currentOrderId && currentOrderId !== orderId) ||
        (pendingOrderId && pendingOrderId !== orderId)) {
      throw new HttpsError("failed-precondition", "Finish your current delivery before accepting another order.");
    }

    const alreadyInProgress = assignedUid === uid && (
      ["picked up", "out for delivery", "arrived", "delivered"].includes(status) ||
      (status === "assigned" && currentOrderId === orderId)
    );
    if (alreadyInProgress) return { accepted: true, alreadyAccepted: true, orderId };

    const pendingAutoAssignment = status === "pending_acceptance" && assignedUid === uid;
    const eligibleUnassignedStatus = [
      "new order", "searching", "ready", "pending", "pending_acceptance", "assigned"
    ].includes(status);
    if (!pendingAutoAssignment && !eligibleUnassignedStatus) {
      throw new HttpsError("failed-precondition", "This order is no longer available to accept.");
    }

    if (!pendingAutoAssignment) {
      const partnerStatus = String(partner.status || "").trim().toLowerCase();
      const online = partnerStatus === "online" &&
        partner.isOnline !== false &&
        partner.availableForDeliveries !== false;
      if (!online) {
        throw new HttpsError("failed-precondition", "Go online and enable delivery availability before accepting orders.");
      }
    }

    const partnerName = String(partner.name || partner.displayName || partner.email || "ALLways Delivery Partner");
    const partnerPhone = String(partner.phone || partner.mobileNumber || "");
    const partnerVehicle = String(partner.vehicleType || "bike");

    tx.update(orderRef, {
      carrierUid: uid,
      deliveryPartnerUid: uid,
      assignedPartnerId: uid,
      carrierName: partnerName,
      carrierPhone: partnerPhone,
      carrierVehicleType: partnerVehicle,
      carrierAccepted: true,
      assignmentRejected: false,
      assignmentMethod: pendingAutoAssignment ? "automatic" : "manual",
      assignmentStatus: "accepted",
      status: "Assigned",
      statusNote: "A delivery partner accepted this order.",
      customerMessage: "Your delivery partner accepted the order.",
      assignedAt: order.assignedAt || FieldValue.serverTimestamp(),
      acceptedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    tx.set(partnerRef, {
      pendingOrderId: null,
      currentOrderId: orderId,
      availableForDeliveries: false,
      dutyStatus: "on_delivery",
      statusUpdatedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    return { accepted: true, alreadyAccepted: false, orderId };
  });
});

// Allow only the assigned delivery partner to advance the order through the
// pickup -> dispatch -> arrival stages. Delivery itself requires the PIN callable.
exports.updateDeliveryOrderStatus = onCall({ region: "asia-south1" }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in is required.");

  const orderId = String(request.data?.orderId || "").trim();
  const requestedStatus = String(request.data?.status || "").trim().toLowerCase();
  const allowedTargets = new Set(["picked up", "out for delivery", "arrived"]);
  if (!orderId || !allowedTargets.has(requestedStatus)) {
    throw new HttpsError("invalid-argument", "A valid order ID and delivery status are required.");
  }

  const orderRef = db.collection("orders").doc(orderId);
  const partnerRef = db.collection("deliveryPartners").doc(uid);
  const normalizedTarget = {
    "picked up": "Picked Up",
    "out for delivery": "Out for delivery",
    "arrived": "Arrived",
  }[requestedStatus];

  return db.runTransaction(async (tx) => {
    const orderSnap = await tx.get(orderRef);
    const partnerSnap = await tx.get(partnerRef);
    if (!orderSnap.exists) throw new HttpsError("not-found", "This delivery order could not be found.");
    if (!partnerSnap.exists) throw new HttpsError("failed-precondition", "Delivery partner profile not found.");

    const order = orderSnap.data() || {};
    const partner = partnerSnap.data() || {};
    const assignedUid = String(
      order.carrierUid || order.deliveryPartnerUid || order.assignedPartnerId || ""
    ).trim();
    if (assignedUid !== uid) {
      throw new HttpsError("permission-denied", "You are not assigned to this delivery.");
    }

    const currentOrderId = String(partner.currentOrderId || partner.pendingOrderId || "").trim();
    if (currentOrderId && currentOrderId !== orderId) {
      throw new HttpsError("failed-precondition", "This delivery is not your active order.");
    }

    const currentStatus = String(order.status || "").trim().toLowerCase();
    if (currentStatus === requestedStatus) {
      return { updated: true, alreadyAtStatus: true, orderId, status: normalizedTarget };
    }

    const validTransition =
      (requestedStatus === "picked up" && ["assigned", "pending_acceptance"].includes(currentStatus)) ||
      (requestedStatus === "out for delivery" && currentStatus === "picked up") ||
      (requestedStatus === "arrived" && currentStatus === "out for delivery");
    if (!validTransition) {
      throw new HttpsError("failed-precondition", "The delivery status changed. Refresh the order before trying again.");
    }

    const update = {
      status: normalizedTarget,
      statusNote: "Delivery partner updated the status to " + normalizedTarget + ".",
      customerMessage: requestedStatus === "picked up"
        ? "Your order has been picked up by the delivery partner."
        : requestedStatus === "out for delivery"
          ? "Your order is out for delivery."
          : "Your delivery partner has arrived. Please provide the 4-digit confirmation PIN.",
      updatedAt: FieldValue.serverTimestamp(),
    };
    if (requestedStatus === "picked up") update.pickedUpAt = FieldValue.serverTimestamp();
    if (requestedStatus === "out for delivery") update.outForDeliveryAt = FieldValue.serverTimestamp();
    if (requestedStatus === "arrived") update.arrivedAt = FieldValue.serverTimestamp();

    tx.update(orderRef, update);
    tx.set(partnerRef, {
      currentOrderId: orderId,
      pendingOrderId: null,
      availableForDeliveries: false,
      dutyStatus: "on_delivery",
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });

    return { updated: true, alreadyAtStatus: false, orderId, status: normalizedTarget };
  });
});

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

    const rideType = normalizeRideVehicleType(ride.rideType || ride.vehicleType || "bike");
    if (!rideType) return;
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
      const normalizedType = normalizeRideVehicleType(p.rideVehicleType || p.vehicleType || p.vehicleCategory || "bike");
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
function normalizeRideVehicleType(value) {
  const v = String(value || "").trim().toLowerCase().replace(/[^a-z0-9]+/g, "_");
  if (["two_wheeler", "motorcycle", "scooter", "bike", "e_bike", "e_bicycle"].includes(v)) return "bike";
  if (["auto", "auto_rickshaw", "e_rickshaw", "three_wheeler", "tuk_tuk"].includes(v)) return "auto";
  if (["car", "cab", "taxi", "taxi_cab", "sedan", "hatchback", "suv", "muv", "luxury_car"].includes(v)) return "car";
  return "";
}

// Server-authoritative Driver Partner shift state. Clients cannot mark themselves
// approved or overwrite assignment status directly.
exports.setPartnerShift = onCall({ region: "asia-south1" }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in is required.");
  const role = String(request.data?.role || "").trim().toLowerCase();
  if (role !== "carrier") throw new HttpsError("invalid-argument", "Unsupported partner shift role.");
  const online = request.data?.online === true;
  const partnerRef = db.collection("ridePartners").doc(uid);

  return db.runTransaction(async (tx) => {
    const partnerSnap = await tx.get(partnerRef);
    if (!partnerSnap.exists) throw new HttpsError("failed-precondition", "Complete your driver profile before changing shift status.");
    const partner = partnerSnap.data() || {};
    if (String(partner.approvalStatus || "").trim().toLowerCase() !== "approved") {
      throw new HttpsError("permission-denied", "Admin approval is required before going online.");
    }
    const rideVehicleType = normalizeRideVehicleType(partner.vehicleType || partner.vehicleCategory || "");
    if (online && !rideVehicleType) {
      throw new HttpsError("failed-precondition", "Your approved profile needs a supported bike, auto or car vehicle type before going online.");
    }

    const activeRideId = String(partner.activeRideId || "").trim();
    let activeRideStillRunning = false;
    if (activeRideId) {
      const rideSnap = await tx.get(db.collection("autoRideRequests").doc(activeRideId));
      if (rideSnap.exists) {
        const rideStatus = String(rideSnap.data()?.status || "").trim().toLowerCase();
        activeRideStillRunning = !["cancelled", "completed", "rejected", "expired", "delivered"].includes(rideStatus);
      }
    }
    if (!online && activeRideStillRunning) {
      throw new HttpsError("failed-precondition", "Complete or resolve your active ride before going offline.");
    }

    const shiftSessionId = online ? crypto.randomUUID() : null;
    tx.set(partnerRef, {
      status: online ? "online" : "offline",
      rideVehicleType: rideVehicleType || partner.rideVehicleType || "",
      shiftStatus: online ? "on_duty" : "off_duty",
      isOnline: online,
      availableForRides: online && !activeRideStillRunning,
      shiftSessionId: online ? shiftSessionId : FieldValue.delete(),
      shiftStartedAt: online ? FieldValue.serverTimestamp() : (partner.shiftStartedAt || null),
      shiftEndedAt: online ? FieldValue.delete() : FieldValue.serverTimestamp(),
      activeRideId: activeRideStillRunning ? activeRideId : FieldValue.delete(),
      statusUpdatedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    return { ok: true, shiftSessionId, shiftStatus: online ? "on_duty" : "off_duty" };
  });
});

// Atomically assign one searching ride to one approved, on-duty driver.
exports.acceptRide = onCall({ region: "asia-south1" }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in is required.");
  const rideId = String(request.data?.rideId || "").trim();
  if (!rideId) throw new HttpsError("invalid-argument", "A ride request ID is required.");

  const rideRef = db.collection("autoRideRequests").doc(rideId);
  const partnerRef = db.collection("ridePartners").doc(uid);
  const settingsSnap = await db.collection("settings").doc("ride").get();
  const radiusKmRaw = Number(settingsSnap.data()?.matchingRadiusKm ?? 7);
  const radiusKm = Number.isFinite(radiusKmRaw) && radiusKmRaw > 0 && radiusKmRaw <= 50 ? radiusKmRaw : 7;

  function kmBetween(aLat, aLng, bLat, bLng) {
    const rad = (value) => value * Math.PI / 180;
    const dLat = rad(bLat - aLat);
    const dLng = rad(bLng - aLng);
    const h = Math.sin(dLat / 2) ** 2 +
      Math.cos(rad(aLat)) * Math.cos(rad(bLat)) * Math.sin(dLng / 2) ** 2;
    return 6371 * 2 * Math.asin(Math.min(1, Math.sqrt(h)));
  }

  return db.runTransaction(async (tx) => {
    const rideSnap = await tx.get(rideRef);
    const partnerSnap = await tx.get(partnerRef);
    if (!rideSnap.exists) throw new HttpsError("not-found", "This ride request no longer exists.");
    if (!partnerSnap.exists) throw new HttpsError("failed-precondition", "Driver profile not found.");
    const ride = rideSnap.data() || {};
    const partner = partnerSnap.data() || {};

    if (String(partner.approvalStatus || "").trim().toLowerCase() !== "approved") {
      throw new HttpsError("permission-denied", "Admin approval is required before accepting rides.");
    }
    const partnerStatus = String(partner.status || "").trim().toLowerCase();
    if (partnerStatus !== "online" ||
        String(partner.shiftStatus || "").trim().toLowerCase() !== "on_duty" ||
        partner.isOnline === false || partner.availableForRides === false) {
      throw new HttpsError("failed-precondition", "Go online and wait for your live location before accepting a ride.");
    }

    const status = String(ride.status || "").trim().toLowerCase();
    const assignedUid = String(ride.driverUid || ride.carrierUid || "").trim();
    const activeRideId = String(partner.activeRideId || "").trim();
    if (status === "accepted" && assignedUid === uid && activeRideId === rideId) {
      return { ok: true, rideId, alreadyAccepted: true };
    }
    if (status !== "searching" || assignedUid) {
      throw new HttpsError("already-exists", "Another driver has already accepted this ride.");
    }
    if (activeRideId) throw new HttpsError("failed-precondition", "Finish your active ride before accepting another.");
    const rejectedBy = Array.isArray(ride.rejectedBy) ? ride.rejectedBy.map(String) : [];
    if (rejectedBy.includes(uid)) throw new HttpsError("permission-denied", "You previously declined this ride.");
    const expiresAt = ride.expiresAt?.toMillis ? ride.expiresAt.toMillis()
      : typeof ride.expiresAt === "number" ? ride.expiresAt : null;
    if ((ride.expiredAt || (expiresAt !== null && expiresAt <= Date.now()))) {
      throw new HttpsError("deadline-exceeded", "This ride request has expired.");
    }

    const requestedType = normalizeRideVehicleType(ride.rideType || ride.vehicleType || "bike");
    const driverType = normalizeRideVehicleType(partner.rideVehicleType || partner.vehicleType || partner.vehicleCategory || "bike");
    if (!["bike", "auto", "car"].includes(requestedType) || requestedType !== driverType) {
      throw new HttpsError("failed-precondition", "This ride type does not match your approved vehicle.");
    }

    const pickupLat = Number(ride.pickupLatitude ?? ride.pickupLat);
    const pickupLng = Number(ride.pickupLongitude ?? ride.pickupLng);
    const driverLat = Number(partner.carrierLat ?? partner.latitude);
    const driverLng = Number(partner.carrierLng ?? partner.longitude);
    if (![pickupLat, pickupLng, driverLat, driverLng].every(Number.isFinite) ||
        Math.abs(pickupLat) > 90 || Math.abs(driverLat) > 90 ||
        Math.abs(pickupLng) > 180 || Math.abs(driverLng) > 180) {
      throw new HttpsError("failed-precondition", "Your live location or the customer's pickup location is not ready. Keep location enabled and retry.");
    }
    if (kmBetween(driverLat, driverLng, pickupLat, pickupLng) > radiusKm) {
      throw new HttpsError("failed-precondition", "The pickup is outside the current matching radius.");
    }

    const driverName = String(partner.name || partner.fullName || partner.displayName || request.auth.token?.name || "ALLways driver").trim();
    const driverPhone = String(partner.phone || partner.phoneNumber || partner.mobile || "").trim();
    const timestamp = FieldValue.serverTimestamp();
    tx.update(rideRef, {
      status: "accepted",
      driverUid: uid,
      driverName,
      driverPhone,
      driverVehicleType: driverType,
      acceptedAt: timestamp,
      updatedAt: timestamp,
    });
    tx.set(partnerRef, {
      activeRideId: rideId,
      availableForRides: false,
      status: "online",
      isOnline: true,
      shiftStatus: "on_duty",
      lastAssignedAt: timestamp,
      statusUpdatedAt: timestamp,
      updatedAt: timestamp,
    }, { merge: true });
    return { ok: true, rideId, alreadyAccepted: false };
  });
});

exports.verifyConfirmationPin = onCall({ region: "asia-south1" }, async (request) => {
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
    if (type === "delivery" &&
        String(data.paymentMethod || "COD").toUpperCase() === "COD" &&
        request.data?.cashCollected !== true) {
      throw new HttpsError("failed-precondition", "Confirm that COD cash was collected before completing this delivery.");
    }

    if (type === "ride") {
      const status = String(data.status || "").toLowerCase();
      if (!["accepted", "arrived"].includes(status)) {
        if (status === "started") return { ok: true, verified: true, alreadyStarted: true };
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
      if (!["out for delivery", "arrived"].includes(status)) {
        if (status === "delivered") return { ok: true, verified: true, alreadyDelivered: true };
        throw new HttpsError("failed-precondition", "Mark the order as arrived before verifying the delivery PIN.");
      }
      tx.update(ref, {
        status: "Delivered",
        deliveryPinVerified: true,
        deliveryPinVerifiedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }

    return { ok: true, verified: true };
  });
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
    const partnerSnap = await tx.get(partnerRef);
    if (!rideSnap.exists) throw new HttpsError("not-found", "The ride could not be found.");
    if (!partnerSnap.exists) throw new HttpsError("failed-precondition", "Driver profile not found.");

    const ride = rideSnap.data() || {};
    const partner = partnerSnap.data() || {};
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
    const shouldGoOnline = partner.isOnline !== false;
    tx.set(partnerRef, {
      // Preserve online/offline choice and the status token used by Firestore rules.
      status: shouldGoOnline ? "online" : "offline",
      isOnline: shouldGoOnline,
      availableForRides: shouldGoOnline,
      activeRideId: null,
      statusUpdatedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
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
    const booking = event.data?.data();
    if (!booking) return;
    const ownerUid = String(booking.ownerUid || "").trim();
    if (!ownerUid) return;
    const negotiated = String(booking.mode || "").toLowerCase() === "negotiation";
    await sendToUser(
      ownerUid,
      negotiated ? "New vehicle booking request" : "New vehicle booking",
      negotiated
        ? "A customer requested your vehicle and would like to discuss the price."
        : "A customer booked your listed vehicle.",
      {
        type: "vehicle_booking_created",
        bookingId: event.params.bookingId,
        vehicleId: String(booking.vehicleId || ""),
        status: String(booking.status || ""),
      },
      "carrier"
    );
  }
);

exports.onVehicleBookingUpdated = onDocumentUpdated(
  "vehicleBookings/{bookingId}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after = event.data.after.data() || {};
    if (String(before.status || "").toLowerCase() === String(after.status || "").toLowerCase()) return;
    const status = String(after.status || "");
    const normalizedStatus = status.trim().toLowerCase();

    // Release a reserved vehicle only when the booking that owns the reservation
    // reaches a terminal state. A later reservation must never be cleared.
    if (["cancelled", "rejected", "completed", "delivered"].includes(normalizedStatus)) {
      const vehicleId = String(after.vehicleId || "").trim();
      if (vehicleId) {
        const vehicleRef = db.collection("vehicles").doc(vehicleId);
        await db.runTransaction(async (tx) => {
          const vehicleSnap = await tx.get(vehicleRef);
          if (!vehicleSnap.exists) return;
          const vehicle = vehicleSnap.data() || {};
          if (String(vehicle.bookingId || "") !== event.params.bookingId) return;
          tx.update(vehicleRef, {
            status: "available",
            listingStatus: "active",
            available: true,
            bookingId: FieldValue.delete(),
            reservedByUid: FieldValue.delete(),
            reservedAt: FieldValue.delete(),
            updatedAt: FieldValue.serverTimestamp(),
          });
        });
      }
    }

    const uid = String(after.customerUid || "").trim();
    if (uid) {
      await sendToUser(
        uid,
        "Vehicle booking update",
        "Your vehicle booking status is " + status + ".",
        { type: "vehicle_booking_status", bookingId: event.params.bookingId, status },
        "customer"
      );
    }
    if (["cancelled", "rejected", "completed", "delivered"].includes(normalizedStatus)) {
      const ownerUid = String(after.ownerUid || "").trim();
      if (ownerUid) {
        await sendToUser(
          ownerUid,
          "Vehicle booking update",
          "A vehicle booking changed to " + status + ".",
          { type: "vehicle_booking_owner_update", bookingId: event.params.bookingId, vehicleId: String(after.vehicleId || ""), status },
          "carrier"
        );
      }
    }
  }
);

// Create a vehicle booking atomically with the vehicle's availability change.
exports.createVehicleBooking = onCall({ region: "asia-south1" }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in is required.");
  const vehicleId = String(request.data?.vehicleId || "").trim();
  const rawMode = String(request.data?.mode || "book").trim().toLowerCase();
  const mode = rawMode === "negotiation" ? "negotiation" : "book";
  if (!vehicleId) throw new HttpsError("invalid-argument", "Choose a vehicle before booking.");

  const vehicleRef = db.collection("vehicles").doc(vehicleId);
  const bookingRef = db.collection("vehicleBookings").doc();
  const customerName = String(request.data?.customerName || request.auth.token?.name || "ALLways customer").trim().slice(0, 120);
  const customerEmail = String(request.auth.token?.email || request.data?.customerEmail || "").trim().slice(0, 254);

  await db.runTransaction(async (tx) => {
    const vehicleSnap = await tx.get(vehicleRef);
    if (!vehicleSnap.exists) throw new HttpsError("not-found", "This vehicle is no longer listed.");
    const vehicle = vehicleSnap.data() || {};
    const ownerUid = String(vehicle.ownerUid || "").trim();
    if (!ownerUid) throw new HttpsError("failed-precondition", "This vehicle has no verified owner.");
    if (ownerUid === uid) throw new HttpsError("failed-precondition", "You cannot book your own vehicle.");
    const status = String(vehicle.status || vehicle.listingStatus || "available").trim().toLowerCase();
    if (vehicle.available === false || !["available", "active", "published", "listed"].includes(status)) {
      throw new HttpsError("failed-precondition", "This vehicle has already been reserved. Refresh the list to see available vehicles.");
    }
    tx.set(bookingRef, {
      vehicleId,
      ownerUid,
      ownerName: String(vehicle.ownerName || "ALLways vehicle owner"),
      customerUid: uid,
      customerName,
      customerEmail,
      category: String(vehicle.category || vehicle.vehicleType || "Vehicle"),
      listedPrice: Number(vehicle.price ?? vehicle.pricePerKm ?? 0),
      mode,
      status: mode === "negotiation" ? "Pending" : "Booked",
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    tx.update(vehicleRef, {
      status: "booked",
      listingStatus: "booked",
      available: false,
      bookingId: bookingRef.id,
      reservedByUid: uid,
      reservedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
  });

  return { ok: true, bookingId: bookingRef.id, status: mode === "negotiation" ? "Pending" : "Booked" };
});

// Return a vehicle owner's contact number only to the customer who created a booking.
exports.getVehicleBookingContact = onCall({ region: "asia-south1" }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in is required.");
  const bookingId = String(request.data?.bookingId || "").trim();
  if (!bookingId) throw new HttpsError("invalid-argument", "A booking ID is required.");

  const bookingSnap = await db.collection("vehicleBookings").doc(bookingId).get();
  if (!bookingSnap.exists) throw new HttpsError("not-found", "Vehicle booking not found.");
  const booking = bookingSnap.data() || {};
  if (String(booking.customerUid || "") !== uid) {
    throw new HttpsError("permission-denied", "You can only view contact details for your own vehicle booking.");
  }
  const bookingStatus = String(booking.status || "").trim().toLowerCase();
  if (!["booked", "pending", "requested", "confirmed", "accepted", "in review", "approved"].includes(bookingStatus)) {
    throw new HttpsError("failed-precondition", "Contact details are available only while your booking is active.");
  }
  const vehicleId = String(booking.vehicleId || "").trim();
  if (!vehicleId) throw new HttpsError("failed-precondition", "This booking has no vehicle reference.");
  const vehicleSnap = await db.collection("vehicles").doc(vehicleId).get();
  if (!vehicleSnap.exists) throw new HttpsError("not-found", "The booked vehicle is no longer listed.");
  const vehicle = vehicleSnap.data() || {};
  const ownerUid = String(booking.ownerUid || vehicle.ownerUid || "").trim();
  if (!ownerUid || String(vehicle.ownerUid || ownerUid) !== ownerUid) {
    throw new HttpsError("permission-denied", "The vehicle owner could not be verified.");
  }
  const contactSnap = await db.collection("vehicleOwnerContacts").doc(vehicleId).get();
  const contact = contactSnap.data() || {};
  // Fallback supports older public listings until the Admin migration has removed
  // ownerPhone from every existing vehicles document.
  const phone = String(contact.phone || contact.ownerPhone || vehicle.ownerPhone || "").trim();
  if (!phone) throw new HttpsError("failed-precondition", "The vehicle owner contact is not available yet. Please contact ALLways support.");
  return {
    ok: true,
    phone,
    ownerName: String(booking.ownerName || vehicle.ownerName || "ALLways vehicle owner"),
  };
});

// One-time migration: move ownerPhone from public vehicle documents to private contact documents.
// The caller (Admin) requests pages so large collections can be migrated without an unbounded function.
exports.migrateVehicleContactPrivacy = onCall(
  { region: "asia-south1", timeoutSeconds: 540, memory: "512MiB", maxInstances: 1 },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in is required.");
    const email = String(request.auth.token?.email || "").trim().toLowerCase();
    if (email !== "mauryasujeet698@gmail.com") {
      throw new HttpsError("permission-denied", "The primary ALLways Admin account is required for this migration.");
    }
    const cursor = String(request.data?.cursor || "").trim();
    const pageSize = 1000;
    let query = db.collection("vehicles").orderBy(FieldPath.documentId()).limit(pageSize);
    if (cursor) query = query.startAfter(cursor);
    const snap = await query.get();
    if (snap.empty) return { ok: true, migrated: 0, nextCursor: cursor, done: true };
    let migrated = 0;
    const eligible = snap.docs.filter((doc) => {
      const data = doc.data() || {};
      const ownerUid = String(data.ownerUid || "").trim();
      const hasPhone = String(data.ownerPhone || "").trim().length > 0;
      const hasPreciseLocation = ["latitude", "longitude", "ownerLat", "ownerLng", "currentLocation"]
        .some((key) => data[key] !== undefined && data[key] !== null);
      return ownerUid && (hasPhone || hasPreciseLocation);
    });
    // Keep every write batch below Firestore's 500-operation limit.
    for (let i = 0; i < eligible.length; i += 200) {
      const batch = db.batch();
      for (const doc of eligible.slice(i, i + 200)) {
        const data = doc.data() || {};
        const phone = String(data.ownerPhone || "").trim();
        if (phone) {
          batch.set(db.collection("vehicleOwnerContacts").doc(doc.id), {
            vehicleId: doc.id,
            ownerUid: String(data.ownerUid).trim(),
            phone,
            updatedAt: FieldValue.serverTimestamp(),
          }, { merge: true });
        }
        batch.update(doc.ref, {
          ownerPhone: FieldValue.delete(),
          latitude: FieldValue.delete(),
          longitude: FieldValue.delete(),
          currentLocation: FieldValue.delete(),
          ownerLat: FieldValue.delete(),
          ownerLng: FieldValue.delete(),
          contactPrivacyMigratedAt: FieldValue.serverTimestamp(),
        });
        migrated++;
      }
      await batch.commit();
    }
    return {
      ok: true,
      migrated,
      nextCursor: snap.docs[snap.docs.length - 1].id,
      done: snap.size < pageSize,
    };
  }
);

// Automatic Google Sheets -> Firestore catalog synchronization.
const { onSchedule } = require("firebase-functions/v2/scheduler");
const CATALOG_SYNC_ENDPOINT = "https://script.google.com/macros/s/AKfycbxnmGS7Q6t7pPWiT50V87JmA0Qbh2tSi1UKLFzN28dQpybjw7vvCufnryi-qpTnq0b0IA/exec";
function catalogColumnKey(value) {
  return String(value ?? "").trim().toLowerCase().replace(/[^a-z0-9]/g, "");
}
function catalogValue(row, headers, name, fallback = "") {
  const target = catalogColumnKey(name);
  if (row && !Array.isArray(row) && typeof row === "object") {
    const key = Object.keys(row).find(k => catalogColumnKey(k) === target);
    return key !== undefined ? row[key] : fallback;
  }
  if (!Array.isArray(row) || !Array.isArray(headers)) return fallback;
  const index = headers.findIndex(h => catalogColumnKey(h) === target);
  return index >= 0 ? row[index] : fallback;
}
function catalogValueAny(row, headers, names, fallback = "") {
  for (const name of names) {
    const value = catalogValue(row, headers, name, null);
    if (value !== null && value !== undefined && String(value).trim() !== "") return value;
  }
  return fallback;
}
function catalogImageUrl(row, headers) {
  const aliases = ["Image URL", "Product Image URL", "Image Link", "Image", "Photo URL", "Photo", "imageUrl"];
  let raw = "";
  for (const alias of aliases) {
    const candidate = catalogValue(row, headers, alias, "");
    if (candidate !== null && candidate !== undefined && String(candidate).trim()) {
      raw = String(candidate).trim();
      break;
    }
  }
  if (!raw) return "";
  const formula = /^=IMAGE\(\s*"([^"]+)"/i.exec(raw);
  if (formula) raw = formula[1].trim();
  if (raw.startsWith("//")) raw = "https:" + raw;
  let parsed;
  try { parsed = new URL(raw); } catch (_) { return ""; }
  if (!["http:", "https:"].includes(parsed.protocol) || !parsed.hostname) return "";
  if (parsed.hostname === "drive.google.com" || parsed.hostname.endsWith(".drive.google.com")) {
    const parts = parsed.pathname.split("/").filter(Boolean);
    const d = parts.indexOf("d");
    const id = (d >= 0 && parts[d + 1]) || parsed.searchParams.get("id");
    if (id) return "https://drive.google.com/uc?export=view&id=" + encodeURIComponent(id);
  }
  return raw;
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
    const response = await fetch(CATALOG_SYNC_ENDPOINT, { redirect: "follow" });
    if (!response.ok) throw new Error("Catalog Apps Script returned HTTP " + response.status);
    const payload = await response.json();
    if (!payload || payload.success !== true) throw new Error("Catalog Apps Script did not return success:true");
    const headers = Array.isArray(payload.headers) ? payload.headers : [];
    // Support both header/row and product-object response shapes from Apps Script.
    const rows = Array.isArray(payload.rows)
      ? payload.rows
      : Array.isArray(payload.products)
        ? payload.products
        : [];
    const contentHash = crypto.createHash("sha256").update(JSON.stringify({ headers, rows })).digest("hex");
    const syncRef = db.collection("settings").doc("catalogSync");
    const previousSync = await syncRef.get();
    if (previousSync.data()?.contentHash === contentHash) {
      await syncRef.set({
        endpoint: CATALOG_SYNC_ENDPOINT, source: "google_sheets", automatic: true,
        schedule: "every 5 minutes", lastCheckedAt: FieldValue.serverTimestamp(),
        lastSyncChanged: false, status: "success",
      }, { merge: true });
      console.log("Catalog sync unchanged; skipped product writes.");
      return;
    }
    let written = 0;
    let deactivated = 0;
    const seenIds = new Set();
    // Each product creates two documents; 200 products = 400 writes, below Firestore's 500-write batch limit.
    for (let i = 0; i < rows.length; i += 200) {
      const batch = db.batch();
      for (const row of rows.slice(i, i + 200)) {
        const rawId = catalogValueAny(row, headers, ["ID", "id", "productId", "product_id"], "");
        const name = String(catalogValueAny(row, headers, ["Product Name", "name", "title", "productName", "product_name"], "")).trim();
        if (!name) continue;
        const fallbackId = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
        const id = String(rawId || fallbackId).trim();
        if (!id || seenIds.has(id)) continue;
        seenIds.add(id);
        const product = {
          id,
          name,
          description: String(catalogValueAny(row, headers, ["Description", "Product Description", "Product Details", "details"], "")).trim(),
          imageVersion: String(catalogValueAny(row, headers, ["Image Version", "Image Updated At", "imageVersion", "image_version"], "")).trim(),
          category: String(catalogValueAny(row, headers, ["Category", "category", "cat"], "")).trim(),
          emoji: String(catalogValueAny(row, headers, ["Emoji", "emoji", "icon"], "")).trim(),
          price: catalogNumber(catalogValueAny(row, headers, ["Price", "price"], 0)),
          stock: catalogNumber(catalogValueAny(row, headers, ["Stock", "stock", "quantity"], 0)),
          available: catalogBool(catalogValueAny(row, headers, ["Available", "available", "active"], true), true),
          maxQty: catalogNumber(catalogValueAny(row, headers, ["Max Qty", "maxQty", "max_qty"], 10), 10),
          imageUrl: catalogImageUrl(row, headers),
          updatedAt: FieldValue.serverTimestamp(),
          source: "google_sheets",
        };
        batch.set(db.collection("products").doc(id), product, { merge: true });
        batch.set(db.collection("inventory").doc(id), {
          id, productId: id, name, description: product.description, imageVersion: product.imageVersion,
          category: product.category, price: product.price, stock: product.stock, available: product.available, maxQty: product.maxQty,
          imageUrl: product.imageUrl, updatedAt: FieldValue.serverTimestamp(), source: "google_sheets",
        }, { merge: true });
        written++;
      }
      await batch.commit();
    }
    if (written === 0) {
      throw new Error("Catalog payload contained no valid named products; refusing to report a successful sync.");
    }

    // Removed source rows are disabled rather than deleted so historical order references remain.
    // This cleanup runs only when the source content hash changes.
    const existingProducts = await db.collection("products").get();
    const staleIds = existingProducts.docs.filter((doc) => !seenIds.has(doc.id)).map((doc) => doc.id);
    for (let i = 0; i < staleIds.length; i += 200) {
      const batch = db.batch();
      for (const id of staleIds.slice(i, i + 200)) {
        batch.set(db.collection("products").doc(id), {
          available: false, stock: 0,
          removedFromCatalogAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(), source: "google_sheets",
        }, { merge: true });
        batch.set(db.collection("inventory").doc(id), {
          available: false, stock: 0,
          removedFromCatalogAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(), source: "google_sheets",
        }, { merge: true });
        deactivated++;
      }
      await batch.commit();
    }

    await db.collection("settings").doc("catalogSync").set({
      endpoint: CATALOG_SYNC_ENDPOINT, source: "google_sheets", automatic: true,
      schedule: "every 5 minutes", lastSyncAt: FieldValue.serverTimestamp(),
      lastRowCount: rows.length, lastWrittenCount: written, lastDisabledCount: deactivated, contentHash,
      lastCheckedAt: FieldValue.serverTimestamp(), lastSyncChanged: true, status: "success",
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
