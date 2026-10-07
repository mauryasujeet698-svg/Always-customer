const {setGlobalOptions} = require("firebase-functions/v2");
const {onDocumentCreated, onDocumentUpdated} = require("firebase-functions/v2/firestore");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
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
    notification: {
      title: String(title || "ALLways"),
      body: String(body || ""),
    },
    android: {
      priority: "high",
      notification: {
        channelId: "allways_updates",
        priority: "high",
        sound: "default",
      },
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
    notification: {
      title: String(title || "ALLways"),
      body: String(body || ""),
    },
    android: {
      priority: "high",
      notification: {
        channelId: "allways_updates",
        priority: "high",
        sound: "default",
      },
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
          console.warn("Token send failed for", uid, token, err.message);
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
    if (statusBefore === statusAfter) return;
    const requesterId = String(after.requesterId || after.customerId || "");
    if (!requesterId) return;
    await sendToUserTokens(requesterId, "Support update",
      "Your support request is now " + statusAfter.replaceAll("_", " "), {
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
