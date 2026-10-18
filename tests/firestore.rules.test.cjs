const fs = require("node:fs");
const path = require("node:path");
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require("@firebase/rules-unit-testing");
const {
  collection,
  doc,
  getDoc,
  getDocs,
  setDoc,
  updateDoc,
} = require("firebase/firestore");
const {before, beforeEach, after, test} = require("node:test");

const projectId = "demo-allways-rules";
const rules = fs.readFileSync(path.join(__dirname, "..", "firestore.rules"), "utf8");
let env;

function signedIn(uid, claims = {}) {
  return env.authenticatedContext(uid, claims).firestore();
}
async function seed(documentPath, data) {
  await env.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), documentPath), data);
  });
}
const order = (id, customerId, extra = {}) => ({
  id,
  customerId,
  name: "Test Customer",
  email: "",
  phone: "9876543210",
  address: "Village Road, Near Market",
  note: "",
  items: [{id: "sku-1", name: "Test item", qty: 1, price: 20}],
  subtotal: 20,
  delivery: 10,
  total: 30,
  paymentMethod: "COD",
  paymentStatus: "unpaid",
  confirmationPin: "1234",
  status: "New Order",
  estimatedDelivery: "",
  statusNote: "Order received",
  cancellationReason: "",
  rating: null,
  createdAt: Date.now(),
  updatedAt: Date.now(),
  time: new Date().toISOString(),
  ...extra,
});

before(async () => {
  env = await initializeTestEnvironment({
    projectId,
    firestore: {rules},
  });
});

beforeEach(async () => {
  await env.clearFirestore();
});

after(async () => {
  if (env) await env.cleanup();
});

test("rejects customer order without a verified phone claim", async () => {
  await assertFails(setDoc(
    doc(signedIn("customer-a"), "orders/order-a"),
    order("order-a", "customer-a"),
  ));
});

test("verified customers still cannot write orders directly from the client", async () => {
  // Customer orders must go through createCustomerOrder, which validates the
  // verified phone and recalculates prices, stock, fees and totals server-side.
  await assertFails(setDoc(
    doc(signedIn("customer-a", {phone_number: "+919876543210"}), "orders/order-a"),
    order("order-a", "customer-a"),
  ));
});

test("rejects another UID and a phone number different from the verified claim", async () => {
  const db = signedIn("customer-a", {phone_number: "+919876543210"});
  await assertFails(setDoc(
    doc(db, "orders/order-b"),
    order("order-b", "customer-b"),
  ));
  await assertFails(setDoc(
    doc(db, "orders/order-c"),
    order("order-c", "customer-a", {phone: "9000000000"}),
  ));
});

test("customers cannot read another customer's order", async () => {
  await seed("orders/order-b", order("order-b", "customer-b"));
  await assertFails(getDoc(doc(signedIn("customer-a"), "orders/order-b")));
  await assertSucceeds(getDoc(doc(signedIn("customer-b"), "orders/order-b")));
});

test("customer cannot change order total, payment status, or delivery assignment", async () => {
  await seed("orders/order-a", order("order-a", "customer-a"));
  const db = signedIn("customer-a");
  await assertFails(updateDoc(doc(db, "orders/order-a"), {total: 1}));
  await assertFails(updateDoc(doc(db, "orders/order-a"), {paymentStatus: "paid"}));
  await assertFails(updateDoc(doc(db, "orders/order-a"), {carrierUid: "attacker"}));
});

test("customer cancellation requires a reason and only allows eligible statuses", async () => {
  await seed("orders/order-a", order("order-a", "customer-a"));
  const db = signedIn("customer-a");
  await assertFails(updateDoc(doc(db, "orders/order-a"), {status: "Cancelled"}));
  await assertSucceeds(updateDoc(doc(db, "orders/order-a"), {
    status: "Cancelled",
    statusNote: "Cancelled by customer",
    cancellationReason: "Placed by mistake",
    updatedAt: Date.now(),
  }));
});

test("approved assigned delivery partner can update live location only", async () => {
  await seed("deliveryPartners/delivery-a", {
    uid: "delivery-a",
    role: "delivery_partner",
    approvalStatus: "approved",
    status: "online",
  });
  await seed("orders/order-a", order("order-a", "customer-a", {
    carrierUid: "delivery-a",
    status: "Assigned",
  }));
  const db = signedIn("delivery-a");
  await assertSucceeds(updateDoc(doc(db, "orders/order-a"), {
    carrierLat: 25.45,
    carrierLng: 81.85,
    carrierLocationUpdatedAt: new Date(),
  }));
  await assertFails(updateDoc(doc(db, "orders/order-a"), {status: "Delivered"}));
});

test("admin custom claim can access all orders", async () => {
  await seed("orders/order-a", order("order-a", "customer-a"));
  const db = signedIn("admin-user", {admin: true});
  await assertSucceeds(getDocs(collection(db, "orders")));
  await assertSucceeds(updateDoc(doc(db, "orders/order-a"), {status: "Confirmed"}));
});

test("users cannot self-approve partner profiles or assign themselves a role", async () => {
  await seed("ridePartners/driver-a", {
    uid: "driver-a",
    role: "carrier",
    approvalStatus: "pending",
    status: "pending",
    availableForRides: false,
  });
  await assertFails(updateDoc(doc(signedIn("driver-a"), "ridePartners/driver-a"), {
    approvalStatus: "approved",
  }));
  await seed("customers/customer-a", {role: "customer"});
  await assertFails(updateDoc(doc(signedIn("customer-a"), "customers/customer-a"), {
    role: "admin",
  }));
});

test("ride creation requires verified phone and caller-owned UID", async () => {
  const newRide = {
    customerId: "customer-a",
    customerName: "Test Customer",
    customerEmail: "",
    customerPhone: "+919876543210",
    pickupAddress: "Current location",
    destinationAddress: "Market",
    pickupLatitude: 25.45,
    pickupLongitude: 81.85,
    destinationLatitude: 25.46,
    destinationLongitude: 81.86,
    rideType: "bike",
    confirmationPin: "1234",
    status: "searching",
    requestedAt: new Date(),
    updatedAt: new Date(),
  };
  await assertFails(setDoc(
    doc(signedIn("customer-a"), "autoRideRequests/ride-a"),
    newRide,
  ));
  await assertFails(setDoc(
    doc(signedIn("customer-a", {phone_number: "+919876543210"}), "autoRideRequests/ride-b"),
    {...newRide, customerId: "customer-b"},
  ));
  await assertSucceeds(setDoc(
    doc(signedIn("customer-a", {phone_number: "+919876543210"}), "autoRideRequests/ride-c"),
    newRide,
  ));
});

test("driver can only read their own dispatch offer", async () => {
  await seed("rideOffers/driver-a/requests/ride-1", {
    rideId: "ride-1", status: "searching", customerActive: true,
  });
  await assertSucceeds(getDoc(doc(signedIn("driver-a"), "rideOffers/driver-a/requests/ride-1")));
  await assertFails(getDoc(doc(signedIn("driver-b"), "rideOffers/driver-a/requests/ride-1")));
});
