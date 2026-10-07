const {setGlobalOptions} = require("firebase-functions/v2");
const {onDocumentCreated, onDocumentUpdated} = require("firebase-functions/v2/firestore");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {initializeApp} = require("firebase-admin/app");
const {getMessaging} = require("firebase-admin/messaging");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {randomInt} = require("crypto");

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

async function writeUserNotification(uid, notificationId, title, body, data = {}) {
  if (!uid) return;
  const db = getFirestore();
  await db.collection("notifications").doc(notificationId).set({
    customerId: String(uid),
    title: String(title || "ALLways"),
    body: String(body || ""),
    type: String(data.type || "update"),
    orderId: data.orderId ? String(data.orderId) : null,
    rideId: data.rideId ? String(data.rideId) : null,
    read: false,
    createdAt: FieldValue.serverTimestamp(),
  }, {merge: true});
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
      const payload = {type: "order_status", orderId, status: nextStatus};
      await writeUserNotification(customerId, "order_status_" + orderId + "_" + nextStatus, title, body, payload);
      await sendToUserTokens(customerId, title, body, payload);
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
        const title = "Order placed";
        const body = "Your ALLways order #" + orderId + " was placed successfully";
        const payload = {type: "order_placed", orderId};
        await writeUserNotification(customerId, "order_placed_" + orderId, title, body, payload);
        await sendToUserTokens(customerId, title, body, payload);
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
          const payload = {type: "ride_assigned", rideId};
          const title = "Rider assigned";
          const body = "A carrier has been assigned to your ride";
          await writeUserNotification(customerId, "ride_assigned_" + rideId, title, body, payload);
          await sendToUserTokens(customerId, title, body, payload);
        }
      }
      if (prevStatus !== nextStatus && nextStatus && customerId) {
        const title = "Ride update";
        const body = "Your ride is now " + (after.status || nextStatus);
        const payload = {type: "ride_status", rideId, status: nextStatus};
        await writeUserNotification(customerId, "ride_status_" + rideId + "_" + nextStatus, title, body, payload);
        await sendToUserTokens(customerId, title, body, payload);
      }
    } catch (error) {
      console.error("notifyRideUpdate failed:", error);
    }
  }
);


/** Server-side confirmation PIN verification for rides and deliveries. */
exports.verifyConfirmationPin = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign-in is required.");
  const type = String(request.data?.type || "").toLowerCase();
  const id = String(request.data?.id || "").trim();
  const pin = String(request.data?.pin || "").trim();
  if (!id || !/^\d{4}$/.test(pin)) throw new HttpsError("invalid-argument", "A valid 4-digit PIN is required.");
  const db = getFirestore();

  if (type === "ride") {
    const ref = db.collection("autoRideRequests").doc(id);
    const snap = await ref.get();
    if (!snap.exists) throw new HttpsError("not-found", "Ride not found.");
    const data = snap.data() || {};
    if (String(data.driverUid || "") !== request.auth.uid) throw new HttpsError("permission-denied", "This ride is not assigned to you.");
    const status = String(data.status || "").toLowerCase();
    if (!["accepted", "arrived"].includes(status)) throw new HttpsError("failed-precondition", "Ride is not waiting for passenger confirmation.");
    if (String(data.confirmationPin || "").trim() !== pin) throw new HttpsError("permission-denied", "Incorrect confirmation number.");
    await ref.update({status:"started",ridePinVerified:true,ridePinVerifiedAt:FieldValue.serverTimestamp(),updatedAt:FieldValue.serverTimestamp()});
    return {verified:true,type:"ride",id};
  }

  if (type === "order") {
    const ref = db.collection("orders").doc(id);
    const snap = await ref.get();
    if (!snap.exists) throw new HttpsError("not-found", "Order not found.");
    const data = snap.data() || {};
    const partner = String(data.deliveryPartnerUid || data.carrierUid || data.deliveryPartnerId || data.assignedPartnerId || "").trim();
    if (partner !== request.auth.uid) throw new HttpsError("permission-denied", "This order is not assigned to you.");
    if (String(data.deliveryPin || "").trim() !== pin) throw new HttpsError("permission-denied", "Incorrect delivery PIN.");
    if (data.deliveryPinVerified === true) return {verified:true,type:"order",id};
    await ref.update({deliveryPinVerified:true,deliveryPinVerifiedAt:FieldValue.serverTimestamp(),verifiedByPartnerUid:request.auth.uid,updatedAt:FieldValue.serverTimestamp()});
    return {verified:true,type:"order",id};
  }

  throw new HttpsError("invalid-argument", "Unsupported confirmation type.");
});
