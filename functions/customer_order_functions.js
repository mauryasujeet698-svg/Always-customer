const crypto = require("node:crypto");
const {getApps, initializeApp} = require("firebase-admin/app");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {onCall, HttpsError} = require("firebase-functions/v2/https");

if (!getApps().length) initializeApp();
const db = getFirestore();

function text(value) {
  return value == null ? "" : String(value).trim();
}
function money(value) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}
function int(value) {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isInteger(parsed) ? parsed : null;
}
function productAvailable(product) {
  const value = product.available ?? product.Available ?? true;
  if (typeof value === "boolean") return value;
  return !["no", "false", "0", "unavailable"].includes(String(value).trim().toLowerCase());
}
function normalizeStock(product) {
  const value = product.stock ?? product.Stock ?? product.quantity ?? product.Quantity;
  return int(value);
}
function productMaximum(product) {
  const value = int(product.maxQty ?? product["Max Qty"]);
  return Math.max(1, Math.min(value == null ? 10 : value, 99));
}
function itemName(product, id) {
  return text(product.name ?? product.title ?? product["Product Name"]) || id;
}

/**
 * Customer orders are created only by trusted server code.
 * The caller sends product IDs and quantities, never trusted prices or totals.
 */
exports.createCustomerOrder = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in before placing an order.");
  }

  const uid = request.auth.uid;
  const verifiedPhone = text(request.auth.token.phone_number);
  if (!/^\+91[0-9]{10}$/.test(verifiedPhone)) {
    throw new HttpsError("failed-precondition", "Verify an Indian mobile number before placing an order.");
  }

  const data = request.data || {};
  const name = text(data.name);
  const address = text(data.address);
  const note = text(data.note);
  const email = text(request.auth.token.email || data.email);
  const requestId = text(data.requestId);
  if (!/^[A-Za-z0-9_-]{16,100}$/.test(requestId)) {
    throw new HttpsError("invalid-argument", "A valid idempotency request ID is required.");
  }
  if (name.length < 1 || name.length > 120) {
    throw new HttpsError("invalid-argument", "Enter your name.");
  }
  if (address.length < 8 || address.length > 600) {
    throw new HttpsError("invalid-argument", "Enter a complete delivery address.");
  }
  if (note.length > 500) {
    throw new HttpsError("invalid-argument", "Delivery note is too long.");
  }
  if (!Array.isArray(data.items) || data.items.length < 1 || data.items.length > 30) {
    throw new HttpsError("invalid-argument", "The order must contain between 1 and 30 line items.");
  }

  const requestedItems = [];
  const seen = new Set();
  for (const raw of data.items) {
    const id = text(raw && raw.id);
    const quantity = int(raw && raw.qty);
    if (!id || id.length > 180 || id.includes("/") || quantity == null || quantity < 1 || quantity > 99) {
      throw new HttpsError("invalid-argument", "One of the requested items is invalid.");
    }
    if (seen.has(id)) {
      throw new HttpsError("invalid-argument", "The cart contains a duplicate product line.");
    }
    seen.add(id);
    requestedItems.push({id, quantity});
  }

  // Idempotency avoids duplicate orders when a mobile connection times out.
  const idempotencyRef = db.collection("orderSubmissionKeys").doc(uid + "_" + requestId);
  const customerPhone = verifiedPhone.slice(3);

  return db.runTransaction(async (transaction) => {
    const previous = await transaction.get(idempotencyRef);
    if (previous.exists) {
      const saved = previous.data() || {};
      if (saved.uid !== uid) {
        throw new HttpsError("permission-denied", "This order request key belongs to another account.");
      }
      return saved.response;
    }

    const productRefs = requestedItems.map((item) => db.collection("products").doc(item.id));
    const productSnapshots = await Promise.all(productRefs.map((ref) => transaction.get(ref)));
    const normalizedItems = [];
    let subtotal = 0;

    for (let index = 0; index < requestedItems.length; index++) {
      const requested = requestedItems[index];
      const snapshot = productSnapshots[index];
      if (!snapshot.exists) {
        throw new HttpsError("failed-precondition", "An item in your cart is no longer available.");
      }
      const product = snapshot.data() || {};
      if (!productAvailable(product)) {
        throw new HttpsError("failed-precondition", itemName(product, requested.id) + " is currently unavailable.");
      }

      const price = money(product.price ?? product.Price);
      const stock = normalizeStock(product);
      if (price == null || price < 0) {
        throw new HttpsError("failed-precondition", "An item has an invalid current price.");
      }
      if (stock == null || stock < requested.quantity) {
        throw new HttpsError("failed-precondition", itemName(product, requested.id) + " does not have enough stock.");
      }
      if (requested.quantity > productMaximum(product)) {
        throw new HttpsError("failed-precondition", itemName(product, requested.id) + " exceeds the order quantity limit.");
      }

      subtotal += price * requested.quantity;
      normalizedItems.push({
        id: requested.id,
        name: itemName(product, requested.id),
        qty: requested.quantity,
        price,
      });
    }

    subtotal = Math.round((subtotal + Number.EPSILON) * 100) / 100;
    const delivery = subtotal >= 499 ? 0 : 30;
    const total = Math.round((subtotal + delivery + Number.EPSILON) * 100) / 100;
    const confirmationPin = String(1000 + crypto.randomInt(0, 9000));
    let visibleId = "";
    let orderRef = null;

    // Keep the document ID equal to the public order ID expected by the
    // existing Admin, Driver and Delivery Partner apps.
    for (let attempt = 0; attempt < 5; attempt++) {
      const timeSuffix = Date.now().toString().slice(-7);
      const randomSuffix = String(crypto.randomInt(0, 10000)).padStart(4, "0");
      visibleId = "AW" + timeSuffix + randomSuffix;
      orderRef = db.collection("orders").doc(visibleId);
      const collision = await transaction.get(orderRef);
      if (!collision.exists) break;
      orderRef = null;
    }
    if (!orderRef) {
      throw new HttpsError("aborted", "Could not allocate an order ID. Please retry.");
    }

    const now = Date.now();
    const order = {
      id: visibleId,
      customerId: uid,
      email,
      name,
      phone: customerPhone,
      address,
      note,
      items: normalizedItems,
      subtotal,
      delivery,
      total,
      paymentMethod: "COD",
      paymentStatus: "unpaid",
      confirmationPin,
      status: "New Order",
      estimatedDelivery: "",
      statusNote: "Order received",
      cancellationReason: "",
      rating: null,
      createdAt: now,
      updatedAt: now,
      time: new Date(now).toString(),
    };

    const response = {
      orderId: visibleId,
      confirmationPin,
      order,
    };
    transaction.create(orderRef, order);
    transaction.create(idempotencyRef, {
      uid,
      requestId,
      orderId: visibleId,
      response,
      createdAt: FieldValue.serverTimestamp(),
    });
    return response;
  });
});
