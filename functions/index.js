const { initializeApp } = require("firebase-admin/app");
const { getMessaging } = require("firebase-admin/messaging");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");

initializeApp();

const db = getFirestore();
const messaging = getMessaging();

function stringData(data = {}) {
  return Object.fromEntries(Object.entries(data).map(([k, v]) => [k, String(v ?? "")]));
}

function notificationMessage(title, body, data = {}, target) {
  return {
    ...target,
    notification: { title, body },
    data: stringData(data),
    android: {
      priority: "high",
      notification: { channelId: "allways_updates" },
    },
  };
}

function preferenceKeyForType(type = "") {
  const t = String(type).toLowerCase();
  if (t.includes("order") || t.includes("delivery")) return "orderUpdates";
  if (t.includes("ride") || t.includes("travel") || t.includes("vehicle")) return "travelUpdates";
  if (t.includes("offer")) return "offers";
  return "announcements";
}

function notificationAllowedFromData(data = {}, type = "") {
  if (data.notificationsEnabled === false) return false;
  const preferences = data.notificationPreferences || {};
  return preferences[preferenceKeyForType(type)] !== false;
}

async function getUserTokens(uid) {
  if (!uid) return [];
  const id = String(uid);
  const parent = await db.collection("fcmTokens").doc(id).get();
  const parentData = parent.exists ? (parent.data() || {}) : {};
  const result = new Map();

  if (parentData.token && parentData.notificationsEnabled !== false) {
    const token = String(parentData.token).trim();
    if (token) {
      result.set(token, {
        token,
        notificationsEnabled: true,
        notificationPreferences: parentData.notificationPreferences || {},
      });
    }
  }

  const snap = await db.collection("fcmTokens").doc(id).collection("tokens").get();
  for (const doc of snap.docs) {
    const data = doc.data() || {};
    if (data.notificationsEnabled === false) continue;
    const token = String(data.token || doc.id).trim();
    if (!token) continue;
    result.set(token, {
      token,
      notificationsEnabled: data.notificationsEnabled !== false,
      notificationPreferences: data.notificationPreferences || parentData.notificationPreferences || {},
    });
  }

  return [...result.values()];
}

async function sendToUser(uid, title, body, data = {}, fallbackToken = "") {
  if (!uid) return false;
  let recipients = await getUserTokens(uid);

  if (!recipients.length && fallbackToken) {
    recipients = [{
      token: String(fallbackToken).trim(),
      notificationsEnabled: true,
      notificationPreferences: {},
    }];
  }

  recipients = recipients.filter(r =>
    notificationAllowedFromData(r, data.type || "")
  );

  if (!recipients.length) {
    console.log("No enabled FCM recipients for:", uid);
    return false;
  }

  const messages = recipients.map(r =>
    notificationMessage(title, body, data, { token: r.token })
  );

  let sent = false;
  for (let i = 0; i < messages.length; i += 500) {
    const response = await messaging.sendEach(messages.slice(i, i + 500));
    response.responses.forEach((result, index) => {
      if (result.success) {
        sent = true;
        return;
      }
      const code = result.error?.code || "";
      if (code.includes("registration-token-not-registered") ||
          code.includes("invalid-registration-token")) {
        const recipient = recipients[i + index];
        if (recipient?.token) {
          db.collection("fcmTokens").doc(String(uid))
            .collection("tokens").doc(recipient.token).delete().catch(() => {});
        }
      }
    });
  }
  return sent;
}

async function sendToAllUsers(title, body, data = {}) {
  const snap = await db.collection("fcmTokens").get();
  const recipients = [];
  for (const doc of snap.docs) {
    const uid = doc.id;
    const tokens = await getUserTokens(uid);
    for (const token of tokens) {
      if (notificationAllowedFromData(token, data.type || "")) {
        recipients.push(token.token);
      }
    }
  }

  const unique = [...new Set(recipients)].filter(Boolean);
  let sent = false;
  for (let i = 0; i < unique.length; i += 500) {
    const messages = unique.slice(i, i + 500).map(token =>
      notificationMessage(title, body, data, { token })
    );
    if (!messages.length) continue;
    const response = await messaging.sendEach(messages);
    if (response.responses.some(r => r.success)) sent = true;
  }
  return sent;
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

async function notifyAdmins(title, body, data = {}) {
  return sendToUser(
    "mauryasujeet698-admin",
    title,
    body,
    data
  );
}

// Order creation: notify the real Admin account. Delivery assignment is manual in Admin.
exports.onAllwaysOrderCreated = onDocumentCreated(
  "orders/{orderId}",
  async (event) => {
    const order = event.data?.data();
    if (!order) return;

    await sendToUser(
      "ADMIN_UID_PLACEHOLDER",
      "New ALLways Order",
      "A new order #" + event.params.orderId + " is waiting for Admin processing.",
      { type: "order_created", orderId: event.params.orderId, status: String(order.status || "New Order") }
    );
  }
);

// Order updates: partner assignment/acceptance and Customer status notifications.
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

    if (newPartner && newPartner !== oldPartner) {
      await sendToUser(
        newPartner,
        "New Delivery Offer",
        "Order #" + orderId + " has been assigned to you. Please accept or reject it.",
        { type: "delivery_offer", orderId, status: newStatus },
        after.carrier_fcm_token || after.partner_fcm_token
      );
    }

    if (oldStatus === "pending_acceptance" && newStatus === "Assigned" && newPartner) {
      await db.collection("deliveryPartners").doc(newPartner).set({
        pendingOrderId: null,
        currentOrderId: orderId,
        availableForDeliveries: false,
        dutyStatus: "on_delivery",
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });

      await sendToUser(
        newPartner,
        "Delivery Assigned",
        "Order #" + orderId + " is now assigned to you.",
        { type: "delivery_assignment", orderId, status: "Assigned" }
      );
    }

    if (oldStatus === "pending_acceptance" && newStatus === "unassigned" && oldPartner) {
      await db.collection("deliveryPartners").doc(oldPartner).set({
        pendingOrderId: null,
        currentOrderId: null,
        availableForDeliveries: true,
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
    }

    if (oldPartner && (newStatus === "Delivered" || newStatus === "Cancelled")) {
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
          "Order Update",
          "Your ALLways order #" + orderId + " is now " + newStatus + ".",
          { type: "order_update", orderId, status: newStatus, normalizedStatus: normalized },
          after.customer_fcm_token || after.fcmToken || ""
        );
      }
    }
  }
);

// New ride request -> all eligible online ride partners within 7 km.
exports.onAutoRideRequestCreated = onDocumentCreated(
  "autoRideRequests/{requestId}",
  async (event) => {
    const ride = event.data?.data();
    if (!ride || String(ride.status || "").toLowerCase() !== "searching") return;

    const rideType = String(ride.rideType || "bike").toLowerCase();
    const pickupLat = Number(ride.pickupLatitude);
    const pickupLng = Number(ride.pickupLongitude);
    if (!Number.isFinite(pickupLat) || !Number.isFinite(pickupLng)) return;

    const snap = await db.collection("ridePartners")
      .where("status", "==", "online")
      .get();

    for (const partner of snap.docs) {
      const p = partner.data() || {};
      const type = String(p.vehicleType || "bike").toLowerCase();
      const normalizedType = type === "two_wheeler" || type === "motorcycle" || type === "scooter"
        ? "bike"
        : type;
      if (normalizedType !== rideType) continue;

      const pLat = Number(p.carrierLat ?? p.latitude);
      const pLng = Number(p.carrierLng ?? p.longitude);
      if (!Number.isFinite(pLat) || !Number.isFinite(pLng)) continue;

      const distance = distanceKm(pickupLat, pickupLng, pLat, pLng);
      if (distance > 7) continue;

      await sendToUser(
        partner.id,
        "New Ride Request",
        "A customer nearby is requesting a " + rideType + " ride.",
        {
          type: "ride_request",
          rideId: event.params.requestId,
          rideType,
          distanceKm: distance.toFixed(1),
        }
      );
    }
  }
);

// Ride state changes -> Customer.
exports.onAutoRideRequestUpdated = onDocumentUpdated(
  "autoRideRequests/{requestId}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after = event.data.after.data() || {};
    const oldStatus = String(before.status || "").toLowerCase();
    const newStatus = String(after.status || "").toLowerCase();
    if (oldStatus === newStatus) return;

    const customerUid = String(after.customerUid || after.customerId || "").trim();
    if (!customerUid) return;

    if (newStatus === "accepted") {
      await sendToUser(
        customerUid,
        "Ride Accepted",
        "Your ALLways ride request has been accepted.",
        { type: "ride_update", rideId: event.params.requestId, status: "accepted" }
      );
    } else if (newStatus === "rejected") {
      await sendToUser(
        customerUid,
        "Ride Update",
        "Your ALLways ride request was rejected.",
        { type: "ride_update", rideId: event.params.requestId, status: "rejected" }
      );
    } else if (newStatus === "cancelled") {
      await sendToUser(
        customerUid,
        "Ride Cancelled",
        "Your ALLways ride request has been cancelled.",
        { type: "ride_update", rideId: event.params.requestId, status: "cancelled" }
      );
    }
  }
);

// Partner registration/approval notifications.
exports.onRidePartnerCreated = onDocumentCreated(
  "ridePartners/{uid}",
  async (event) => {
    const data = event.data?.data() || {};
    await sendToUser(
      "ADMIN_UID_PLACEHOLDER",
      "New Rider Registration",
      "A new rider registration is waiting for approval.",
      { type: "partner_registration", role: "carrier", uid: event.params.uid }
    );
  }
);

exports.onDeliveryPartnerCreated = onDocumentCreated(
  "deliveryPartners/{uid}",
  async (event) => {
    await sendToUser(
      "ADMIN_UID_PLACEHOLDER",
      "New Delivery Partner",
      "A new delivery partner registration is waiting for approval.",
      { type: "partner_registration", role: "delivery_partner", uid: event.params.uid }
    );
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
      "Rider Approval Update",
      "Your ALLways rider account is now " + status + ".",
      { type: "partner_approval", role: "carrier", status }
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
      "Delivery Partner Approval Update",
      "Your ALLways delivery partner account is now " + status + ".",
      { type: "partner_approval", role: "delivery_partner", status }
    );
  }
);

exports.onNotificationBroadcastCreated = onDocumentCreated(
  "notificationBroadcasts/{notificationId}",
  async (event) => {
    const ref = event.data?.ref;
    const notification = event.data?.data();
    if (!ref || !notification) return;

    const title = String(notification.title || "ALLways");
    const body = String(notification.body || "New ALLways update.");
    const data = notification.data || {};
    const sent = await sendToAllUsers(title, body, data);

    await ref.set({
      status: sent ? "sent" : "failed",
      sentAt: FieldValue.serverTimestamp(),
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
    await messaging.send(
      notificationMessage(
        title,
        body,
        { type: "announcement", announcementId: event.params.announcementId },
        { topic: "all_users" }
      )
    );
  }
);
