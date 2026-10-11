"use strict";

const crypto = require("crypto");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");

const db = getFirestore();

function money(value) {
  return Math.round((Number(value) + Number.EPSILON) * 100) / 100;
}
function finite(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}
function distanceKm(lat1, lon1, lat2, lon2) {
  const rad = Math.PI / 180;
  const p1 = lat1 * rad, p2 = lat2 * rad;
  const dLat = (lat2 - lat1) * rad, dLon = (lon2 - lon1) * rad;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dLon / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(Math.max(0, 1 - a)));
}
function newConfirmationPin() {
  return String(crypto.randomInt(0, 10000)).padStart(4, "0");
}
function pincodeFrom(value) {
  return String(value || "").replace(/\D/g, "").slice(0, 6);
}
function scheduledMinuteInIndia(date) {
  const parts = new Intl.DateTimeFormat("en-IN", {
    timeZone: "Asia/Kolkata",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  const part = (type) => Number(parts.find((x) => x.type === type)?.value || 0);
  return part("hour") * 60 + part("minute");
}
function isSameIndiaDay(a, b) {
  const f = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Kolkata", year: "numeric", month: "2-digit", day: "2-digit" });
  return f.format(a) === f.format(b);
}
function textField(value, max, label, required = false) {
  const v = String(value ?? "").trim();
  if (required && !v) throw new HttpsError("invalid-argument", label + " is required.");
  if (v.length > max) throw new HttpsError("invalid-argument", label + " is too long.");
  return v;
}

const createCustomerOrder = onCall({ region: "asia-south1", maxInstances: 100 }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in before placing an order.");

  const paymentMethod = String(request.data?.paymentMethod || "COD").trim().toUpperCase();
  // UPI/card options are displayed as unavailable in the UI. The server refuses
  // client attempts to submit a non-COD method until a verified provider is integrated.
  if (paymentMethod !== "COD") throw new HttpsError("failed-precondition", "Online payments are currently unavailable. Please select Cash on Delivery.");

  const name = textField(request.data?.name, 80, "Name", true);
  const phone = String(request.data?.phone || "").replace(/\D/g, "");
  if (!/^\d{10}$/.test(phone)) throw new HttpsError("invalid-argument", "A valid 10-digit mobile number is required.");
  const address = textField(request.data?.address, 500, "Delivery address", true);
  const note = textField(request.data?.note, 1000, "Order note");
  const pin = pincodeFrom(request.data?.deliveryPincode || request.data?.pincode);
  const deliveryType = String(request.data?.deliveryType || "instant").toLowerCase();
  if (!["instant", "scheduled"].includes(deliveryType)) throw new HttpsError("invalid-argument", "Unsupported delivery type.");
  if (!Array.isArray(request.data?.items) || request.data.items.length < 1 || request.data.items.length > 30) {
    throw new HttpsError("invalid-argument", "An order must contain between 1 and 30 distinct items.");
  }

  const itemsById = new Map();
  for (const raw of request.data.items) {
    const id = String(raw?.id || "").trim();
    const qty = Number(raw?.qty ?? raw?.quantity);
    if (!id || id.length > 180 || !Number.isInteger(qty) || qty < 1 || qty > 30) {
      throw new HttpsError("invalid-argument", "Each item needs a valid ID and quantity between 1 and 30.");
    }
    itemsById.set(id, (itemsById.get(id) || 0) + qty);
  }
  if (itemsById.size > 30) throw new HttpsError("invalid-argument", "Too many distinct products in one order.");

  const latitude = request.data?.latitude == null ? null : finite(request.data.latitude);
  const longitude = request.data?.longitude == null ? null : finite(request.data.longitude);
  if ((latitude == null) !== (longitude == null) ||
      (latitude != null && (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180))) {
    throw new HttpsError("invalid-argument", "Pickup coordinates are invalid.");
  }

  const requestedTime = request.data?.scheduledFor == null ? null : new Date(Number(request.data.scheduledFor));
  if (deliveryType === "scheduled" && (!requestedTime || !Number.isFinite(requestedTime.getTime()))) {
    throw new HttpsError("invalid-argument", "Choose a valid scheduled delivery time.");
  }

  const settingsRef = db.collection("settings").doc("delivery");
  const zoneRef = pin ? db.collection("serviceableZones").doc(pin) : null;
  const productEntries = [...itemsById.entries()];
  const refs = productEntries.map(([id]) => ({
    id,
    productRef: db.collection("products").doc(id),
    inventoryRef: db.collection("inventory").doc(id),
    qty: itemsById.get(id),
  }));
  const orderId = "AW" + crypto.randomBytes(7).toString("hex").toUpperCase();
  const orderRef = db.collection("orders").doc(orderId);
  const privatePinRef = db.collection("customerPrivatePins").doc("delivery_" + orderId);
  const reservationRef = db.collection("inventoryReservations").doc(orderId);
  const customer = request.auth.token || {};

  const result = await db.runTransaction(async (tx) => {
    // All reads happen before the first write; Firestore may retry this transaction.
    const baseReads = [tx.get(settingsRef)];
    if (zoneRef) baseReads.push(tx.get(zoneRef));
    for (const item of refs) {
      baseReads.push(tx.get(item.productRef));
      baseReads.push(tx.get(item.inventoryRef));
    }
    const loaded = await Promise.all(baseReads);
    const settings = loaded[0].data() || {};
    let offset = 1;
    let zone = null;
    if (zoneRef) zone = loaded[offset++].data() || null;

    if (settings.deliveryEnabled === false) throw new HttpsError("failed-precondition", "ALLways delivery is temporarily unavailable.");
    if (deliveryType === "scheduled" && settings.scheduledEnabled === false) throw new HttpsError("failed-precondition", "Scheduled delivery is currently unavailable.");
    if (deliveryType === "instant" && settings.instantEnabled === false) throw new HttpsError("failed-precondition", "Instant delivery is currently unavailable.");

    if (pin) {
      if (!zone || String(zone.status || "").toLowerCase() !== "serviceable") {
        throw new HttpsError("failed-precondition", "This PIN code is not currently serviceable by ALLways.");
      }
    } else if (!(Number(settings.pilotCenterLat) && Number(settings.pilotCenterLng) && latitude != null)) {
      throw new HttpsError("failed-precondition", "A serviceable PIN code or configured delivery zone is required.");
    }

    if (deliveryType === "scheduled") {
      const now = new Date();
      if (requestedTime < new Date(now.getTime() + 30 * 60 * 1000)) {
        throw new HttpsError("invalid-argument", "Scheduled orders must be at least 30 minutes in the future.");
      }
      if (!isSameIndiaDay(now, requestedTime) && requestedTime < new Date(now.getTime() + 24 * 60 * 60 * 1000)) {
        throw new HttpsError("invalid-argument", "Choose a valid scheduled delivery slot.");
      }
      const startMinute = Math.max(0, Math.min(1439, Math.trunc(Number(settings.scheduledStartHour ?? 9)) * 60 + Math.trunc(Number(settings.scheduledStartMinute ?? 0))));
      const endMinute = Math.max(0, Math.min(1439, Math.trunc(Number(settings.scheduledEndHour ?? 13)) * 60 + Math.trunc(Number(settings.scheduledEndMinute ?? 30))));
      const targetMinute = scheduledMinuteInIndia(requestedTime);
      if (targetMinute < startMinute || targetMinute > endMinute) {
        throw new HttpsError("invalid-argument", "The selected time is outside the scheduled delivery window.");
      }
    }

    const centerLat = finite(settings.pilotCenterLat) ?? 0;
    const centerLng = finite(settings.pilotCenterLng) ?? 0;
    const radius = finite(settings.pilotRadiusKm) ?? 4;
    let distance = 0;
    if (centerLat !== 0 && centerLng !== 0) {
      if (latitude == null || longitude == null) {
        throw new HttpsError("failed-precondition", "Current location is needed to verify this delivery zone.");
      }
      distance = distanceKm(latitude, longitude, centerLat, centerLng);
      if (radius > 0 && distance > radius) {
        throw new HttpsError("failed-precondition", "This address is outside the current ALLways delivery area.");
      }
    }

    const trustedItems = [];
    let subtotal = 0;
    const inventoryWrites = [];
    for (const item of refs) {
      const productSnap = loaded[offset++];
      const inventorySnap = loaded[offset++];
      const product = productSnap.data() || {};
      const inventory = inventorySnap.data() || {};
      if (!productSnap.exists && !inventorySnap.exists) throw new HttpsError("not-found", "A product is no longer available.");
      const productName = String(product.name || product.title || inventory.name || "Product").trim().slice(0, 160);
      const price = money(finite(product.price ?? inventory.price) ?? -1);
      const available = product.available !== false && inventory.available !== false;
      const stockValue = finite(inventory.stock ?? product.stock);
      const reserved = Math.max(0, finite(inventory.reservedQty) ?? 0);
      const qty = item.qty;
      if (!available || price < 0 || stockValue == null || stockValue - reserved < qty) {
        throw new HttpsError("failed-precondition", productName + " is no longer available in the requested quantity.");
      }
      const lineTotal = money(price * qty);
      subtotal = money(subtotal + lineTotal);
      trustedItems.push({ id: item.id, name: productName, qty, price, lineTotal });
      inventoryWrites.push({
        ref: item.inventoryRef,
        exists: inventorySnap.exists,
        data: inventory,
        product,
        stock: stockValue,
        reservedQty: reserved + qty,
        name: productName,
        price,
        qty,
      });
    }

    const threshold = finite(settings.freeScheduledThreshold) ?? 499;
    const chargeableKm = distance <= 0 ? 0 : Math.max(1, Math.ceil(distance));
    const scheduledFree = deliveryType === "scheduled" && subtotal >= threshold;
    const deliveryFee = deliveryType === "scheduled"
      ? (scheduledFree ? 0 : chargeableKm * (finite(settings.scheduledPerKm) ?? 11))
      : (finite(settings.instantBaseFee) ?? 35) + chargeableKm * (finite(settings.instantPerKm) ?? 11);
    const total = money(subtotal + deliveryFee);

    const createdAt = FieldValue.serverTimestamp();
    for (const reservation of inventoryWrites) {
      const patch = {
        id: reservation.data.id || reservation.ref.id,
        productId: reservation.ref.id,
        name: reservation.name,
        price: reservation.price,
        stock: reservation.stock,
        reservedQty: reservation.reservedQty,
        available: true,
        updatedAt: createdAt,
      };
      if (reservation.exists) tx.update(reservation.ref, { reservedQty: reservation.reservedQty, updatedAt: createdAt });
      else tx.set(reservation.ref, patch);
    }

    tx.set(orderRef, {
      id: orderId,
      customerId: uid,
      customerUid: uid,
      email: String(customer.email || "").slice(0, 254),
      name,
      phone,
      address,
      note,
      customerLatitude: latitude,
      customerLongitude: longitude,
      locationSource: latitude != null && longitude != null ? "gps" : "address",
      items: trustedItems,
      subtotal,
      delivery: money(deliveryFee),
      deliveryFee: money(deliveryFee),
      total,
      deliveryType,
      scheduledFor: requestedTime ? requestedTime.getTime() : null,
      deliveryDistanceKm: distance,
      deliveryChargeableKm: chargeableKm,
      freeScheduledDelivery: scheduledFree,
      freeScheduledThreshold: threshold,
      deliveryPricingRule: deliveryType === "scheduled"
        ? (scheduledFree ? "scheduled_free_over_threshold" : "scheduled_per_km")
        : "instant_base_plus_per_km",
      deliveryZoneId: pin ? "pincode_" + pin : "pilot_zone",
      deliveryZoneName: pin ? String(zone?.label || ("PIN " + pin)) : "ALLways Pilot Zone",
      deliveryPincode: pin,
      paymentMethod: "COD",
      paymentStatus: "cash_on_delivery",
      status: "New Order",
      estimatedDelivery: "",
      eta: "",
      carrierUid: null,
      deliveryPartnerUid: null,
      assignedPartnerId: null,
      carrierAccepted: false,
      deliveryPinVerified: false,
      deliveryPinVerifiedAt: null,
      statusNote: "Order received",
      customerMessage: "Order received",
      cancellationReason: "",
      rating: null,
      createdAt,
      updatedAt: createdAt,
      time: new Date().toISOString(),
      source: "customer_android",
    });

    tx.set(privatePinRef, {
      customerUid: uid,
      recordId: orderId,
      type: "delivery",
      confirmationPin: newConfirmationPin(),
      attempts: 0,
      createdAt,
      expiresAt: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000),
    });
    tx.set(reservationRef, {
      orderId,
      customerUid: uid,
      status: "reserved",
      items: inventoryWrites.map((item) => ({ productId: item.ref.id, qty: item.qty })),
      createdAt,
      updatedAt: createdAt,
    });

    return { orderId, subtotal, deliveryFee: money(deliveryFee), total, deliveryDistanceKm: distance };
  });

  return { ok: true, ...result };
});

module.exports = { createCustomerOrder };
