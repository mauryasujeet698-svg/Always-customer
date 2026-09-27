const { initializeApp } = require("firebase-admin/app");
const { getMessaging } = require("firebase-admin/messaging");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");

initializeApp();

const db = getFirestore();
const messaging = getMessaging();

function stringData(data = {}) {
  return Object.fromEntries(
    Object.entries(data).map(([key, value]) => [key, String(value ?? "")])
  );
}

function notificationMessage(title, body, data = {}, target) {
  return {
    ...target,
    notification: { title, body },
    data: stringData(data),
    android: {
      priority: "high",
      notification: {
        channelId: "allways_updates",
      },
    },
  };
}

async function sendToToken(token, title, body, data = {}) {
  const clean = String(token || "").trim();
  if (!clean) return false;

  try {
    await messaging.send(
      notificationMessage(title, body, data, { token: clean })
    );
    return true;
  } catch (error) {
    console.error("FCM token send failed:", error);
    if (
      error?.code === "messaging/registration-token-not-registered" ||
      error?.code === "messaging/invalid-registration-token"
    ) {
      const tokenSnap = await db
        .collection("fcmTokens")
        .where("token", "==", clean)
        .limit(10)
        .get();

      const batch = db.batch();
      for (const doc of tokenSnap.docs) batch.delete(doc.ref);
      if (!tokenSnap.empty) await batch.commit();
    }
    return false;
  }
}

async function getUserTokens(uid) {
  if (!uid) return [];
  const tokens = new Map();

  const parent = await db.collection("fcmTokens").doc(String(uid)).get();
  const parentData = parent.exists ? (parent.data() || {}) : {};
  if (parentData.notificationsEnabled !== false && parentData.token) {
    tokens.set(String(parentData.token).trim(), {
      notificationsEnabled: true,
      notificationPreferences: parentData.notificationPreferences || {},
    });
  }

  const snap = await db
    .collection("fcmTokens")
    .doc(String(uid))
    .collection("tokens")
    .get();

  for (const doc of snap.docs) {
    const data = doc.data() || {};
    const token = String(data.token || doc.id).trim();
    if (!token) continue;
    tokens.set(token, {
      notificationsEnabled: data.notificationsEnabled !== false,
      notificationPreferences: data.notificationPreferences || parentData.notificationPreferences || {},
    });
  }

  if (parentData.notificationsEnabled === false) return [];
  return [...tokens.entries()].map(([token, meta]) => ({ token, ...meta }));
}

function notificationAllowedFromData(data = {}, type = "") {
  if (data.notificationsEnabled === false) return false;
  const preferences = data.notificationPreferences || {};
  const key = preferenceKeyForType(type);
  return preferences[key] !== false;
}

async function notificationAllowed(uid, type = "") {
  if (!uid) return false;
  const parent = await db.collection("fcmTokens").doc(String(uid)).get();
  if (!parent.exists) return false;
  return notificationAllowedFromData(parent.data() || {}, type);
}

async function sendToUser(uid, title, body, data = {}, fallbackToken = "") {
  if (!uid) return false;
  if (!(await notificationAllowed(uid, data.type || ""))) {
    console.log("Notification category disabled for user:", uid, data.type || "");
    return false;
  }

  const recipients = await getUserTokens(uid);
  if (!recipients.length && fallbackToken) {
    recipients.push({
      token: String(fallbackToken).trim(),
      notificationsEnabled: true,
      notificationPreferences: {},
    });
  }
  if (!recipients.length) {
    console.log("No FCM tokens for user:", uid);
    return false;
  }

  const messages = recipients
    .filter((recipient) => notificationAllowedFromData(recipient, data.type || ""))
    .map((recipient) =>
      notificationMessage(title, body, data, { token: recipient.token })
    );

  let sent = false;
  for (let i = 0; i < messages.length; i += 500) {
    const batch = messages.slice(i, i + 500);
    if (!batch.length) continue;
    const response = await messaging.sendEach(batch);
    response.responses.forEach((result, index) => {
      if (result.success) {
        sent = true;
        return;
      }
      const code = result.error?.code;
      if (
        code === "messaging/registration-token-not-registered" ||
        code === "messaging/invalid-registration-token"
      ) {
        const token = recipients[i + index]?.token;
        if (token) {
          db.collection("fcmTokens")
            .doc(String(uid))
            .collection("tokens")
            .doc(token)
            .delete()
            .catch(() => {});
          db.collection("fcmTokens")
            .doc(String(uid))
            .get()
            .then((snap) => {
              if (snap.exists && snap.data()?.token === token) {
                return db.collection("fcmTokens").doc(String(uid)).set(
                  { token: "", updatedAt: FieldValue.serverTimestamp() },
                  { merge: true }
                );
              }
              return null;
            })
            .catch(() => {});
        }
      }
    });
  }

  return sent;
}

async function getSellerAssignmentMode(order) {
  const sellerId = String(
    order?.sellerId || order?.sellerUid || order?.vendorId || ""
  ).trim();

  if (sellerId) {
    const seller = await db.collection("sellers").doc(sellerId).get();
    if (seller.exists) {
      return String(seller.data()?.assignment_mode || "manual").toLowerCase();
    }
  }

  // Backward-compatible fallback for existing ALLways managed orders.
  const global = await db.collection("settings").doc("deliveryAssignment").get();
  if (global.exists && String(global.data()?.mode || "").toLowerCase() === "automatic") {
    return "auto";
  }

  return "manual";
}

async function getAvailablePartners() {
  const result = new Map();

  // Current ALLways schema: customers/{uid}, role=carrier.
  const customers = await db
    .collection("customers")
    .where("role", "==", "carrier")
    .get();

  for (const doc of customers.docs) {
    const data = doc.data() || {};
    const duty = String(data.dutyStatus || "offline").toLowerCase();
    if (
      duty === "online" &&
      data.deliveryAvailable === true &&
      !data.activeOrderId &&
      !data.pendingOrderId
    ) {
      result.set(doc.id, { ref: doc.ref, data, collection: "customers" });
    }
  }

  // Also support the requested delivery_partners schema if it exists.
  const deliveryPartners = await db
    .collection("delivery_partners")
    .where("isAvailable", "==", true)
    .get();

  for (const doc of deliveryPartners.docs) {
    const data = doc.data() || {};
    if (!data.currentOrderId && !data.pendingOrderId && !result.has(doc.id)) {
      result.set(doc.id, {
        ref: doc.ref,
        data,
        collection: "delivery_partners",
      });
    }
  }

  return [...result.entries()].map(([id, value]) => ({ id, ...value }));
}

async function assignAvailablePartner(orderId) {
  const orderRef = db.collection("orders").doc(orderId);
  const initial = await orderRef.get();
  if (!initial.exists) return false;

  const order = initial.data() || {};
  if (order.carrierUid || order.assignedPartnerId) return false;

  const mode = await getSellerAssignmentMode(order);
  if (mode !== "auto") {
    console.log("Order " + orderId + ": assignment mode is " + mode);
    return false;
  }

  const candidates = await getAvailablePartners();

  for (const partner of candidates) {
    try {
      let assigned = false;

      await db.runTransaction(async (tx) => {
        const latestOrder = await tx.get(orderRef);
        const latestPartner = await tx.get(partner.ref);

        if (!latestOrder.exists || !latestPartner.exists) return;

        const currentOrder = latestOrder.data() || {};
        const currentPartner = latestPartner.data() || {};

        if (currentOrder.carrierUid || currentOrder.assignedPartnerId) return;

        const available =
          partner.collection === "delivery_partners"
            ? currentPartner.isAvailable === true && !currentPartner.currentOrderId
            : String(currentPartner.dutyStatus || "offline").toLowerCase() === "online" &&
              currentPartner.deliveryAvailable === true &&
              !currentPartner.activeOrderId;

        if (!available) return;

        const name = String(
          currentPartner.displayName ||
          currentPartner.name ||
          currentPartner.email ||
          partner.id
        );

        const phone = String(
          currentPartner.phone ||
          currentPartner.mobileNumber ||
          ""
        );

        tx.update(orderRef, {
          carrierUid: partner.id,
          assignedPartnerId: partner.id,
          carrierName: name,
          carrierPhone: phone,
          carrierEmail: String(currentPartner.email || ""),
          carrierAccepted: false,
          assignmentRejected: false,
          assignmentMode: "auto",
          pendingAcceptanceAt: FieldValue.serverTimestamp(),
          assignedAt: FieldValue.serverTimestamp(),
          status: "pending_acceptance",
          statusNote: "Pending delivery partner acceptance",
          customerMessage: "A delivery partner has been offered this order. Waiting for acceptance.",
          updatedAt: FieldValue.serverTimestamp(),
        });

        if (partner.collection === "delivery_partners") {
          tx.set(
            partner.ref,
            {
              pendingOrderId: orderId,
              updatedAt: FieldValue.serverTimestamp(),
            },
            { merge: true }
          );
        } else {
          tx.set(
            partner.ref,
            {
              pendingOrderId: orderId,
              updatedAt: FieldValue.serverTimestamp(),
            },
            { merge: true }
          );
        }

        assigned = true;
      });

      if (assigned) {
        return true;
      }
    } catch (error) {
      console.error("Partner assignment attempt failed:", partner.id, error);
    }
  }

  console.log("No available partner could be assigned:", orderId);
  return false;
}

exports.onAllwaysOrderCreated = onDocumentCreated(
  "orders/{orderId}",
  async (event) => {
    if (!event.data) return;
    await assignAvailablePartner(event.params.orderId);
  }
);

exports.onAllwaysOrderUpdated = onDocumentUpdated(
  "orders/{orderId}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after = event.data.after.data() || {};
    const orderId = event.params.orderId;

    const oldStatus = String(before.status || "");
    const newStatus = String(after.status || "");
    const oldCarrier = String(before.carrierUid || "");
    const newCarrier = String(after.carrierUid || after.assignedPartnerId || "");

    if (
      !newCarrier &&
      oldCarrier &&
      newStatus !== "Cancelled" &&
      newStatus !== "Delivered"
    ) {
      await assignAvailablePartner(orderId);
    }

    if (newCarrier && newCarrier !== oldCarrier) {
      await sendToUser(
        newCarrier,
        "New Delivery Offer",
        "You have a new ALLways delivery offer for order #" + orderId + ". Accept or reject it in the app.",
        {
          type: "delivery_offer",
          orderId,
          partnerId: newCarrier,
          status: newStatus,
        },
        after.carrier_fcm_token || after.partner_fcm_token
      );
    }

    if (oldStatus === "pending_acceptance" && newStatus === "Assigned" && newCarrier) {
      const partnerRef = db.collection("customers").doc(newCarrier);
      const partner = await partnerRef.get();
      if (partner.exists) {
        await partnerRef.set({
          pendingOrderId: null,
          activeOrderId: orderId,
          deliveryAvailable: false,
          updatedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
      }

      const requestedPartner = await db.collection("delivery_partners").doc(newCarrier).get();
      if (requestedPartner.exists) {
        await requestedPartner.ref.set({
          pendingOrderId: null,
          currentOrderId: orderId,
          isAvailable: false,
          updatedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
      }

      await sendToUser(
        newCarrier,
        "Delivery Accepted",
        "Your ALLways delivery assignment is confirmed.",
        { type: "delivery_assignment", orderId, partnerId: newCarrier, status: "Assigned" }
      );
    }

    if (oldStatus === "pending_acceptance" && newStatus === "unassigned" && oldCarrier) {
      const partnerRef = db.collection("customers").doc(oldCarrier);
      const partner = await partnerRef.get();
      if (partner.exists) {
        const data = partner.data() || {};
        const duty = String(data.dutyStatus || "offline").toLowerCase();
        await partnerRef.set({
          pendingOrderId: null,
          activeOrderId: null,
          deliveryAvailable: duty === "online",
          updatedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
      }

      const requestedPartner = await db.collection("delivery_partners").doc(oldCarrier).get();
      if (requestedPartner.exists) {
        const data = requestedPartner.data() || {};
        await requestedPartner.ref.set({
          pendingOrderId: null,
          currentOrderId: null,
          isAvailable: String(data.status || "offline") === "online",
          updatedAt: FieldValue.serverTimestamp(),
        }, { merge: true });
      }
    }

    if (oldCarrier && (newStatus === "Delivered" || newStatus === "Cancelled")) {
      const partnerRef = db.collection("customers").doc(oldCarrier);
      const partner = await partnerRef.get();

      if (partner.exists) {
        const data = partner.data() || {};
        const duty = String(data.dutyStatus || "offline").toLowerCase();

        await partnerRef.set(
          {
            pendingOrderId: null,
            activeOrderId: null,
            deliveryAvailable: duty === "online",
            updatedAt: FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
      }

      const requestedPartner = await db
        .collection("delivery_partners")
        .doc(oldCarrier)
        .get();

      if (requestedPartner.exists) {
        const data = requestedPartner.data() || {};
        await requestedPartner.ref.set(
          {
            pendingOrderId: null,
            currentOrderId: null,
            isAvailable: String(data.status || "offline") === "online",
            updatedAt: FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
      }
    }

    if (oldStatus !== newStatus) {
      const customerUid = String(
        after.customerUid || after.customerId || ""
      ).trim();

      const fallbackToken =
        after.customer_fcm_token ||
        after.fcmToken ||
        "";

      let title = "Order Update";
      let body = "Your ALLways order #" + orderId + " is now " + newStatus + ".";

      const normalized = newStatus.toLowerCase().replace(/\s+/g, "_");
      if (normalized === "out_for_delivery") {
        title = "Out for delivery";
        body = "Your ALLways order #" + orderId + " is on the way.";
      } else if (normalized === "delivered") {
        title = "Order delivered";
        body = "Your ALLways order #" + orderId + " has been delivered.";
      }

      if (customerUid) {
        await sendToUser(
          customerUid,
          title,
          body,
          {
            type: normalized === "out_for_delivery" ? "delivery_update" : "order_update",
            orderId,
            status: newStatus,
          },
          fallbackToken
        );
      }
    }
  }
);

exports.onRideBookingCreated = onDocumentCreated(
  "rideBookings/{bookingId}",
  async (event) => {
    const booking = event.data?.data();
    if (!booking) return;

    const partnerUid = String(
      booking.partnerUid || booking.ridePartnerUid || ""
    ).trim();

    if (!partnerUid) return;

    await sendToUser(
      partnerUid,
      "New Ride Booking",
      "A customer has booked a ride with you.",
      {
        type: "ride_booking",
        bookingId: event.params.bookingId,
      },
      booking.partner_fcm_token
    );
  }
);


exports.onRideBookingUpdated = onDocumentUpdated(
  "rideBookings/{bookingId}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after = event.data.after.data() || {};
    const oldStatus = String(before.status || "").toLowerCase();
    const newStatus = String(after.status || "").toLowerCase();
    if (oldStatus === newStatus) return;

    const customerUid = String(after.customerUid || "").trim();
    if (!customerUid) return;

    if (newStatus === "accepted") {
      await sendToUser(
        customerUid,
        "Ride Accepted",
        "Your ALLways ride partner accepted the booking. Live tracking is available.",
        { type: "ride_update", bookingId: event.params.bookingId, status: "Accepted" },
        after.customer_fcm_token
      );
    } else if (newStatus === "rejected") {
      await sendToUser(
        customerUid,
        "Ride Request Rejected",
        "The selected ride partner rejected the request.",
        { type: "ride_update", bookingId: event.params.bookingId, status: "Rejected" },
        after.customer_fcm_token
      );
    }
  }
);

exports.onVehicleBookingCreated = onDocumentCreated(
  "vehicleBookings/{bookingId}",
  async (event) => {
    const booking = event.data?.data();
    if (!booking) return;

    const ownerUid = String(
      booking.ownerUid || booking.vehicleOwnerUid || ""
    ).trim();

    if (!ownerUid) return;

    await sendToUser(
      ownerUid,
      "New Vehicle Booking",
      "A customer has booked your vehicle on ALLways.",
      {
        type: "vehicle_booking",
        bookingId: event.params.bookingId,
      },
      booking.owner_fcm_token
    );
  }
);

async function getAvailableRidePartners(rideType) {
  const snap = await db.collection("ridePartners").where("status", "==", "online").get();
  return snap.docs.filter((doc) => {
    const data = doc.data() || {};
    const type = String(data.vehicleType || "").toLowerCase();
    return (type === rideType || (rideType === "bike" && type === "two_wheeler"));
  });
}

exports.onAutoRideRequestCreated = onDocumentCreated(
  "autoRideRequests/{requestId}",
  async (event) => {
    const ride = event.data?.data();
    if (!ride || String(ride.status || "").toLowerCase() !== "searching") return;

    const rideType = String(ride.rideType || "bike").toLowerCase();
    const partners = await getAvailableRidePartners(rideType);
    const pickupLat = Number(ride.pickupLatitude);
    const pickupLng = Number(ride.pickupLongitude);

    for (const partner of partners) {
      const data = partner.data() || {};
      const pLat = Number(data.latitude);
      const pLng = Number(data.longitude);
      if (!Number.isFinite(pickupLat) || !Number.isFinite(pickupLng) ||
          !Number.isFinite(pLat) || !Number.isFinite(pLng)) continue;

      const distance = distanceKm(pickupLat, pickupLng, pLat, pLng);
      if (distance > 10) continue;

      await sendToUser(
        partner.id,
        "New " + (rideType === "auto" ? "Auto" : "Bike") + " Ride",
        "A nearby ALLways ride request is waiting for acceptance.",
        {
          type: "ride_request",
          rideId: event.params.requestId,
          rideType,
          distanceKm: distance.toFixed(1),
        },
        data.fcmToken || data.fcm_token || ""
      );
    }
  }
);

exports.notifyNearbyRidePartners = onDocumentCreated(
  "rides/{rideId}",
  async (event) => {
    const ride = event.data?.data();
    if (!ride) return;

    const lat = Number(ride.pickupLatitude);
    const lng = Number(ride.pickupLongitude);

    if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
      console.log("Ride has no pickup coordinates:", event.params.rideId);
      return;
    }

    const partners = await getAvailablePartners();
    const recipients = [];

    for (const partner of partners) {
      const p = partner.data || {};
      const pLat = Number(p.latitude);
      const pLng = Number(p.longitude);
      if (!Number.isFinite(pLat) || !Number.isFinite(pLng)) continue;

      const distance = distanceKm(lat, lng, pLat, pLng);
      if (distance > 10) continue;

      const token =
        String(p.fcmToken || p.fcm_token || "").trim() ||
        (await getUserToken(partner.id));

      if (token) recipients.push({ partner, token, distance });
    }

    const messages = recipients.map(({ partner, token, distance }) =>
      notificationMessage(
        "New Ride Available",
        "A new ride request is available near you.",
        {
          type: "new_ride",
          rideId: event.params.rideId,
          distanceKm: distance.toFixed(1),
        },
        { token }
      )
    );

    for (let i = 0; i < messages.length; i += 500) {
      const batch = messages.slice(i, i + 500);
      if (batch.length) await messaging.sendEach(batch);
    }
  }
);

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

    await ref.set(
      {
        status: sent ? "sent" : "failed",
        sentAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
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
    try {
      await messaging.send(
        notificationMessage(
          title,
          body,
          {
            type: "announcement",
            announcementId: event.params.announcementId,
          },
          { topic: "all_users" }
        )
      );
    } catch (error) {
      console.error("ALLways announcement notification failed:", error);
    }
  }
);
