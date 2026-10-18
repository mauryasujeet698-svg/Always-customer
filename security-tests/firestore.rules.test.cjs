const fs = require("node:fs");
const path = require("node:path");
const { after, before, test } = require("node:test");
const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require("@firebase/rules-unit-testing");
const { doc, getDoc, setDoc, updateDoc } = require("firebase/firestore");

const rules = fs.readFileSync(path.join(__dirname, "../firestore.rules"), "utf8");
let env;

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-allways-rules-test",
    firestore: { rules },
  });
  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, "orders/order-1"), {
      customerId: "customer-1",
      carrierUid: "driver-1",
      status: "New Order",
      total: 100,
    });
    await setDoc(doc(db, "autoRideRequests/ride-1"), {
      customerUid: "customer-1",
      driverUid: "driver-1",
      status: "accepted",
      pickupLat: 26.9,
      pickupLng: 80.9,
    });
  });
});

after(async () => {
  if (env) await env.cleanup();
});

test("customer can read their own order but another customer cannot", async () => {
  const ownerDb = env.authenticatedContext("customer-1").firestore();
  const otherDb = env.authenticatedContext("customer-2").firestore();

  await assertSucceeds(getDoc(doc(ownerDb, "orders/order-1")));
  await assertFails(getDoc(doc(otherDb, "orders/order-1")));
});

test("customer cannot create an order for another user", async () => {
  const ownerDb = env.authenticatedContext("customer-1").firestore();
  const otherDb = env.authenticatedContext("customer-2").firestore();

  await assertSucceeds(setDoc(doc(ownerDb, "orders/order-owned"), {
    customerId: "customer-1",
    status: "New Order",
  }));
  await assertFails(setDoc(doc(otherDb, "orders/order-spoofed"), {
    customerId: "customer-1",
    status: "New Order",
  }));
});

test("assigned driver can update only allowed order location fields", async () => {
  const driverDb = env.authenticatedContext("driver-1").firestore();
  await assertSucceeds(updateDoc(doc(driverDb, "orders/order-1"), {
    carrierLat: 26.91,
    carrierLng: 80.91,
  }));
  await assertFails(updateDoc(doc(driverDb, "orders/order-1"), {
    status: "Delivered",
  }));
});

test("customer can cancel an eligible order but cannot change its assignment", async () => {
  const customerDb = env.authenticatedContext("customer-1").firestore();
  await assertSucceeds(updateDoc(doc(customerDb, "orders/order-1"), {
    status: "Cancelled",
  }));
  await assertFails(updateDoc(doc(customerDb, "orders/order-1"), {
    carrierUid: "driver-2",
  }));
});

test("ride requests are private to their customer, assigned driver, and admin", async () => {
  const ownerDb = env.authenticatedContext("customer-1").firestore();
  const otherDb = env.authenticatedContext("customer-2").firestore();
  const driverDb = env.authenticatedContext("driver-1").firestore();

  await assertSucceeds(getDoc(doc(ownerDb, "autoRideRequests/ride-1")));
  await assertFails(getDoc(doc(otherDb, "autoRideRequests/ride-1")));
  await assertSucceeds(getDoc(doc(driverDb, "autoRideRequests/ride-1")));
});

test("assigned driver can update ride location but cannot forge ride status", async () => {
  const driverDb = env.authenticatedContext("driver-1").firestore();
  await assertSucceeds(updateDoc(doc(driverDb, "autoRideRequests/ride-1"), {
    driverLat: 26.91,
    driverLng: 80.91,
  }));
  await assertFails(updateDoc(doc(driverDb, "autoRideRequests/ride-1"), {
    status: "completed",
  }));
});

test("customer cannot create a ride request under another user's identity", async () => {
  const otherDb = env.authenticatedContext("customer-2").firestore();
  await assertFails(setDoc(doc(otherDb, "autoRideRequests/ride-spoofed"), {
    customerUid: "customer-1",
    status: "searching",
  }));
});
