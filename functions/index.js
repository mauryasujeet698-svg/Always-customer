const {setGlobalOptions} = require("firebase-functions/v2");
const {onDocumentCreated, onDocumentUpdated} = require("firebase-functions/v2/firestore");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {initializeApp} = require("firebase-admin/app");
const {getMessaging} = require("firebase-admin/messaging");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");

initializeApp();

setGlobalOptions({
  region: "asia-south1",
  maxInstances: 10,
});

const ALLOWED_TOPICS = new Set([
  "all_users",
  "admins",
  "carriers",
  "delivery_partners",
  "customers",
]);

async function sendToTopic(topic, title, body, data = {}) {
  const t = String(topic || "").trim();
  if (!ALLOWED_TOPICS.has(t)) {
    throw new Error("Invalid notification topic: " + t);
  }
  await getMessaging().send({
    topic: t,
    android: {
      priority: "high",
      notification: { priority: "high", sound: "default" },
    },
    notification: {
      title: String(title || "ALLways"),
      body: String(body || ""),
    },
    data: Object.fromEntries(
      Object.entries(data).map(([k, v]) => [k, String(v ?? "")])
    ),
  });
}

async function sendToToken(token, title, body, data = {}) {
  if (!token) return;
  await getMessaging().send({
    token: String(token),
    android: {
      priority: "high",
      notification: { priority: "high", sound: "default" },
    },
    notification: {
      title: String(title || "ALLways"),
      body: String(body || ""),
    },
    data: Object.fromEntries(
      Object.entries(data).map(([k, v]) => [k, String(v ?? "")])
    ),
  });
}

async function sendToUserTokens(uid, title, body, data = {}) {
  if (!uid) return;
  const db = getFirestore();
  const snap = await db.collection("fcmTokens").doc(uid).collection("tokens").get();
  const sends = [];
  snap.forEach((doc) => {
    const token = (doc.data() || {}).token || doc.id;
    if (token) {
      sends.push(
        sendToToken(token, title, body, data).catch((err) => {
          console.warn("FCM token send failed", { code: String(err?.code || "unknown") });
        })
      );
    }
  });
  await Promise.all(sends);
}

/** Admin announcements -> FCM topic */
exports.sendAnnouncement = onDocumentCreated(
  "announcements/{announcementId}",
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) return;

    const data = snapshot.data() || {};
    if (data.status === "sent") return;

    const topic = String(data.topic || data.targetAudience || "all_users").trim();
    if (!ALLOWED_TOPICS.has(topic)) {
      await snapshot.ref.update({
        status: "failed",
        error: "Invalid notification topic",
      });
      return;
    }

    const title = String(data.title || "ALLways").trim();
    const body = String(data.body || "").trim();

    try {
      await sendToTopic(topic, title, body, {
        announcementId: event.params.announcementId,
        type: String(data.type || "announcement"),
        topic,
      });
      await snapshot.ref.update({
        status: "sent",
        sentAt: FieldValue.serverTimestamp(),
      });
    } catch (error) {
      console.error("ALLways announcement notification failed:", error);
      await snapshot.ref.update({
        status: "failed",
        error: String(error && error.message ? error.message : error),
      });
      throw error;
    }
  }
);

/** Order created/updated -> notify customer + assigned partner */
exports.notifyOrderChange = onDocumentUpdated(
  "orders/{orderId}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after = event.data.after.data() || {};
    const orderId = event.params.orderId;

    const prevStatus = String(before.status || "").toLowerCase();
    const nextStatus = String(after.status || "").toLowerCase();
    const prevPartner = String(
      before.carrierUid ||
      before.deliveryPartnerUid ||
      before.deliveryPartnerId ||
      before.assignedPartnerId ||
      ""
    );
    const nextPartner = String(
      after.carrierUid ||
      after.deliveryPartnerUid ||
      after.deliveryPartnerId ||
      after.assignedPartnerId ||
      ""
    );

    const customerId = String(after.customerId || after.uid || after.userId || "");
    const title = "ALLways order update";
    let body = "";

    if (prevPartner !== nextPartner && nextPartner) {
      body = "A delivery partner was assigned to order #" + orderId;
      await sendToUserTokens(nextPartner, "New delivery assignment",
        "You have been assigned order #" + orderId, {
          type: "order_assigned",
          orderId,
        });
      await sendToTopic("delivery_partners", "New delivery assignment",
        "Order #" + orderId + " needs a partner", {
          type: "order_assigned",
          orderId,
        }).catch(() => {});
    }

    if (prevStatus !== nextStatus && nextStatus) {
      body = "Order #" + orderId + " is now " + (after.status || nextStatus);
      if (nextPartner) {
        await sendToUserTokens(nextPartner, "Delivery update",
          "Order #" + orderId + " is now " + (after.status || nextStatus), {
            type: "order_status",
            orderId,
            status: nextStatus,
          }).catch(() => {});
      }
    }

    if (body && customerId) {
      await sendToUserTokens(customerId, title, body, {
        type: "order_status",
        orderId,
        status: nextStatus,
      });
    }
  }
);

/** New grocery order created -> notify delivery partners topic */
exports.notifyNewOrder = onDocumentCreated(
  "orders/{orderId}",
  async (event) => {
    const data = event.data ? event.data.data() || {} : {};
    const orderId = event.params.orderId;
    const customerId = String(data.customerId || data.uid || "");
    try {
      await sendToTopic("delivery_partners", "New order available",
        "Order #" + orderId + " is waiting for a delivery partner", {
          type: "new_order",
          orderId,
        });
      if (customerId) {
        await sendToUserTokens(customerId, "Order placed",
          "Your ALLways order #" + orderId + " was placed successfully", {
            type: "order_placed",
            orderId,
          });
      }
    } catch (error) {
      console.error("notifyNewOrder failed:", error);
    }
  }
);

/** Ride request created/updated -> notify carriers */
exports.notifyRideRequest = onDocumentCreated(
  "autoRideRequests/{rideId}",
  async (event) => {
    const data = event.data ? event.data.data() || {} : {};
    const rideId = event.params.rideId;
    try {
      await sendToTopic("carriers", "New ride request",
        "A nearby ride request is available (#" + rideId + ")", {
          type: "ride_request",
          rideId,
        });
      const customerId = String(data.customerId || data.uid || data.userId || "");
      if (customerId) {
        await sendToUserTokens(customerId, "Searching for a rider",
          "We are finding a carrier for your ride", {
            type: "ride_searching",
            rideId,
          });
      }
    } catch (error) {
      console.error("notifyRideRequest failed:", error);
    }
  }
);


/** Customer-authoritative ride cancellation. Stops carrier search immediately. */
exports.cancelRide = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign-in required.");
  const rideId = String(request.data?.rideId || "").trim();
  if (!rideId) throw new HttpsError("invalid-argument", "rideId is required.");
  const db = getFirestore();
  const ref = db.collection("autoRideRequests").doc(rideId);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError("not-found", "Ride not found.");
    const data = snap.data() || {};
    const owner = String(data.customerId || data.customerUid || data.uid || "");
    if (owner !== request.auth.uid) throw new HttpsError("permission-denied", "This ride does not belong to you.");
    const status = String(data.status || "").toLowerCase();
    if (!["searching", "accepted", "arrived"].includes(status)) {
      throw new HttpsError("failed-precondition", "This ride can no longer be cancelled.");
    }
    tx.update(ref, {
      status: "cancelled",
      cancelledBy: "customer",
      cancellationReason: String(request.data?.reason || "Customer cancelled the ride"),
      cancelledAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    if (data.driverUid) {
      tx.set(db.collection("ridePartners").doc(String(data.driverUid)), {
        activeRideId: null,
        availableForRides: true,
        status: "online",
        statusUpdatedAt: FieldValue.serverTimestamp(),
      }, {merge: true});
    }
  });
  return {ok: true, rideId};
});

/** Expire unmatched ride searches after 30 minutes. */
exports.expireUnmatchedRides = onSchedule({schedule: "every 5 minutes", timeZone: "Asia/Kolkata"}, async () => {
  const db = getFirestore();
  const cutoff = Date.now() - (30 * 60 * 1000);
  const snap = await db.collection("autoRideRequests").where("status", "==", "searching").limit(100).get();
  const batch = db.batch();
  let changed = 0;
  for (const doc of snap.docs) {
    const data = doc.data() || {};
    const raw = data.requestedAt;
    const requestedMs = raw && typeof raw.toMillis === "function" ? raw.toMillis() : Date.parse(String(raw || ""));
    if (!requestedMs || requestedMs > cutoff) continue;
    batch.update(doc.ref, {
      status: "expired",
      expiredAt: FieldValue.serverTimestamp(),
      cancellationReason: "No Driver Partner found within 30 minutes.",
      updatedAt: FieldValue.serverTimestamp(),
    });
    changed++;
  }
  if (changed) await batch.commit();
  return {expired: changed};
});

/** Authoritative 4-digit delivery/ride confirmation. */
exports.acceptDeliveryOrder = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign-in required.");
  const orderId = String(request.data?.orderId || request.data?.id || "").trim();
  if (!orderId) throw new HttpsError("invalid-argument", "Order ID is required.");

  const db = getFirestore();
  const orderRef = db.collection("orders").doc(orderId);
  const partnerRef = db.collection("deliveryPartners").doc(request.auth.uid);

  await db.runTransaction(async (tx) => {
    const [orderSnap, partnerSnap] = await Promise.all([
      tx.get(orderRef),
      tx.get(partnerRef),
    ]);
    if (!orderSnap.exists) throw new HttpsError("not-found", "Order not found.");
    if (!partnerSnap.exists) throw new HttpsError("failed-precondition", "Delivery partner profile is missing.");

    const order = orderSnap.data() || {};
    const partner = partnerSnap.data() || {};
    const assigned = String(order.carrierUid || order.deliveryPartnerUid || order.deliveryPartnerId || order.assignedPartnerId || "");
    const status = String(order.status || "").trim().toLowerCase();

    if (assigned && assigned !== request.auth.uid) {
      throw new HttpsError("aborted", "This order is already assigned to another delivery partner.");
    }
    if (!["new order", "searching", "ready", "pending", "pending_acceptance", "assigned", ""].includes(status)) {
      throw new HttpsError("failed-precondition", "This order is no longer available.");
    }
    if (String(partner.approvalStatus || "").toLowerCase() !== "approved") {
      throw new HttpsError("failed-precondition", "Admin approval is required.");
    }
    const duty = String(partner.status || partner.dutyStatus || "").toLowerCase();
    if (duty !== "online") {
      throw new HttpsError("failed-precondition", "Go online before accepting delivery work.");
    }

    tx.update(orderRef, {
      carrierUid: request.auth.uid,
      deliveryPartnerUid: request.auth.uid,
      carrierName: partner.name || partner.displayName || "ALLways Delivery Partner",
      carrierPhone: partner.phone || partner.mobileNumber || "",
      carrierVehicleType: partner.vehicleType || "bike",
      status: "Assigned",
      carrierAccepted: true,
      assignedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    tx.set(partnerRef, {
      currentOrderId: orderId,
      pendingOrderId: null,
      lastAcceptedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
  });

  return {ok: true, orderId};
});

exports.updateDeliveryOrderStatus = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign-in required.");
  const orderId = String(request.data?.orderId || request.data?.id || "").trim();
  const requested = String(request.data?.status || "").trim().toLowerCase();
  if (!orderId) throw new HttpsError("invalid-argument", "Order ID is required.");

  const normalized = {
    "assigned": "Assigned",
    "pending_acceptance": "Assigned",
    "picked up": "Picked Up",
    "picked_up": "Picked Up",
    "out for delivery": "Out for delivery",
    "out_for_delivery": "Out for delivery",
    "arrived": "Arrived",
  }[requested];
  if (!normalized) throw new HttpsError("invalid-argument", "Unsupported delivery status.");

  const db = getFirestore();
  const ref = db.collection("orders").doc(orderId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Order not found.");

  const data = snap.data() || {};
  const assigned = String(data.carrierUid || data.deliveryPartnerUid || data.deliveryPartnerId || data.assignedPartnerId || "");
  if (assigned !== request.auth.uid) {
    throw new HttpsError("permission-denied", "This delivery is not assigned to you.");
  }

  const current = String(data.status || "").trim().toLowerCase();
  const allowed = {
    "assigned": ["picked up"],
    "pending_acceptance": ["picked up"],
    "picked up": ["out for delivery"],
    "out for delivery": ["arrived"],
    "arrived": [],
  };
  const requestedKey = requested === "picked_up" ? "picked up" : requested;
  if (!(allowed[current] || []).includes(requestedKey)) {
    throw new HttpsError("failed-precondition", "Delivery cannot move from " + (data.status || "its current state") + " to " + normalized + ".");
  }

  const patch = {
    status: normalized,
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: request.auth.uid,
    statusNote: "Updated by ALLways Delivery Partner",
  };
  if (normalized === "Picked Up") patch.pickedUpAt = FieldValue.serverTimestamp();
  if (normalized === "Out for delivery") patch.outForDeliveryAt = FieldValue.serverTimestamp();
  if (normalized === "Arrived") patch.arrivedAt = FieldValue.serverTimestamp();

  await ref.update(patch);
  await db.collection("deliveryPartners").doc(request.auth.uid).set({
    currentOrderId: orderId,
    lastDeliveryStatus: normalized,
    statusUpdatedAt: FieldValue.serverTimestamp(),
  }, {merge: true});

  return {ok: true, orderId, status: normalized};
});

exports.verifyConfirmationPin = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign-in required.");
  const type = String(request.data?.type || "ride").trim().toLowerCase();
  const id = String(request.data?.id || request.data?.rideId || request.data?.orderId || "").trim();
  const pin = String(request.data?.pin || "").trim();
  if (!id) throw new HttpsError("invalid-argument", type === "delivery" ? "Order ID is required." : "Ride ID is required.");
  if (!/^\d{4}$/.test(pin)) throw new HttpsError("invalid-argument", "Enter the 4-digit confirmation number.");

  const db = getFirestore();

  if (type === "delivery") {
    const ref = db.collection("orders").doc(id);
    const snap = await ref.get();
    if (!snap.exists) throw new HttpsError("not-found", "Order not found.");
    const data = snap.data() || {};
    const assigned = String(data.carrierUid || data.deliveryPartnerUid || data.deliveryPartnerId || data.assignedPartnerId || "");
    if (assigned !== request.auth.uid) {
      throw new HttpsError("permission-denied", "This delivery is not assigned to you.");
    }
    const status = String(data.status || "").toLowerCase();
    if (!["out for delivery", "arrived"].includes(status)) {
      throw new HttpsError("failed-precondition", "Delivery is not ready for customer confirmation.");
    }
    if (String(data.confirmationPin || "").trim() !== pin) {
      throw new HttpsError("permission-denied", "Incorrect confirmation number.");
    }

    const isCod = String(data.paymentMethod || "COD").toUpperCase() === "COD";
    const cashCollected = Boolean(request.data?.cashCollected);
    if (isCod && !cashCollected) {
      throw new HttpsError("failed-precondition", "Cash collection must be confirmed before completion.");
    }

    const patch = {
      status: "Delivered",
      deliveryPinVerified: true,
      deliveryPinVerifiedAt: FieldValue.serverTimestamp(),
      deliveredAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
      completedBy: request.auth.uid,
    };
    if (isCod) {
      patch.cashCollected = true;
      patch.cashCollectedAt = FieldValue.serverTimestamp();
      patch.paymentStatus = "paid";
    }
    await ref.update(patch);
    await db.collection("deliveryPartners").doc(request.auth.uid).set({
      status: "online",
      dutyStatus: "online",
      isOnline: true,
      availableForDeliveries: true,
      currentOrderId: null,
      pendingOrderId: null,
      lastDeliveredAt: FieldValue.serverTimestamp(),
      statusUpdatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
    return {ok: true, orderId: id};
  }

  const ref = db.collection("autoRideRequests").doc(id);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Ride not found.");
  const data = snap.data() || {};
  if (String(data.driverUid || "") !== request.auth.uid) {
    throw new HttpsError("permission-denied", "This ride is not assigned to you.");
  }
  const status = String(data.status || "").toLowerCase();
  if (!["accepted", "arrived"].includes(status)) {
    throw new HttpsError("failed-precondition", "Ride is not waiting for passenger confirmation.");
  }
  if (String(data.confirmationPin || "").trim() !== pin) {
    throw new HttpsError("permission-denied", "Incorrect confirmation number.");
  }

  await ref.update({
    status: "started",
    ridePinVerified: true,
    ridePinVerifiedAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
    startedBy: request.auth.uid,
  });
  await db.collection("ridePartners").doc(request.auth.uid).set({
    status: "on_trip",
    availableForRides: false,
    activeRideId: id,
    statusUpdatedAt: FieldValue.serverTimestamp(),
  }, {merge: true});

  return {ok: true, rideId: id};
});

/** Authoritative ride completion. Carrier cannot mark an unrelated ride completed. */
exports.completeRide = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign-in required.");
  const rideId = String(request.data?.rideId || "").trim();
  if (!rideId) throw new HttpsError("invalid-argument", "rideId is required.");
  const db = getFirestore();
  const ref = db.collection("autoRideRequests").doc(rideId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Ride not found.");
  const data = snap.data() || {};
  if (String(data.driverUid || "") !== request.auth.uid) {
    throw new HttpsError("permission-denied", "This ride is not assigned to you.");
  }
  if (String(data.status || "").toLowerCase() !== "started") {
    throw new HttpsError("failed-precondition", "Ride must be started before completion.");
  }
  await ref.update({
    status: "completed",
    completedAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
    completedBy: request.auth.uid,
  });
  await db.collection("ridePartners").doc(request.auth.uid).set({
    status: "online",
    availableForRides: true,
    activeRideId: null,
    statusUpdatedAt: FieldValue.serverTimestamp(),
  }, {merge: true});
  return {ok: true};
});


/** Support tickets -> notify Admin and requester when status changes */
exports.notifySupportTicket = onDocumentCreated(
  "supportTickets/{ticketId}",
  async (event) => {
    const data = event.data ? event.data.data() || {} : {};
    const ticketId = event.params.ticketId;
    const subject = String(data.subject || data.category || "Support request");
    await sendToTopic("admins", "New support request", subject, {
      type: "support_ticket",
      ticketId,
      queue: String(data.queue || "Customer Support"),
    }).catch(() => {});
  }
);

exports.notifySupportTicketUpdate = onDocumentUpdated(
  "supportTickets/{ticketId}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after = event.data.after.data() || {};
    const statusBefore = String(before.status || "");
    const statusAfter = String(after.status || "");
    const replyBefore = String(before.adminReply || "");
    const replyAfter = String(after.adminReply || "");
    if (statusBefore === statusAfter && replyBefore === replyAfter) return;
    const requesterId = String(after.requesterId || after.customerId || "");
    if (!requesterId) return;
    const body = replyAfter !== replyBefore && replyAfter
      ? "ALLways Support replied to your request."
      : "Your support request is now " + statusAfter.replaceAll("_", " ");
    await sendToUserTokens(requesterId, "Support update", body, {
      type: "support_update",
      ticketId: event.params.ticketId,
      status: statusAfter,
    }).catch(() => {});
  }
);


exports.notifyRideUpdate = onDocumentUpdated(
  "autoRideRequests/{rideId}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after = event.data.after.data() || {};
    const rideId = event.params.rideId;
    const prevStatus = String(before.status || "").toLowerCase();
    const nextStatus = String(after.status || "").toLowerCase();
    const prevDriver = String(before.driverUid || "");
    const nextDriver = String(after.driverUid || "");
    const customerId = String(after.customerId || after.uid || after.userId || "");

    try {
      if (prevDriver !== nextDriver && nextDriver) {
        await sendToUserTokens(nextDriver, "Ride accepted",
          "You accepted ride #" + rideId, {type: "ride_accepted", rideId});
        if (customerId) {
          await sendToUserTokens(customerId, "Rider assigned",
            "A carrier has been assigned to your ride", {
              type: "ride_assigned",
              rideId,
            });
        }
      }
      if (prevStatus !== nextStatus && nextStatus && customerId) {
        await sendToUserTokens(customerId, "Ride update",
          "Your ride is now " + (after.status || nextStatus), {
            type: "ride_status",
            rideId,
            status: nextStatus,
          });
      }
    } catch (error) {
      console.error("notifyRideUpdate failed:", error);
    }
  }
);
