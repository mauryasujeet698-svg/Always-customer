"use strict";

const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require("@firebase/rules-unit-testing");
const {
  doc,
  getDoc,
  setDoc,
  updateDoc,
} = require("firebase/firestore");

let env;

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-allways-rules",
    firestore: {
      rules: fs.readFileSync(path.resolve(__dirname, "../../firestore.rules"), "utf8"),
    },
  });
});

test.after(async () => {
  await env?.cleanup();
});

test.beforeEach(async () => {
  await env.clearFirestore();
});

test("seller cannot self-approve; allowed profile fields remain editable", async () => {
  const db = env.authenticatedContext("seller-1").firestore();
  const seller = doc(db, "sellers/seller-1");

  await assertSucceeds(setDoc(seller, {
    role: "seller",
    name: "Seller",
    approvalStatus: "pending",
    status: "pending",
    businessName: "First Name",
    items: [],
  }));

  await assertSucceeds(updateDoc(seller, { businessName: "Updated Shop" }));
  await assertFails(updateDoc(seller, { approvalStatus: "approved" }));
  await assertFails(updateDoc(seller, { status: "approved" }));
  await assertFails(updateDoc(seller, { isVerified: true }));
});

test("seller records containing private owner details are not public-readable", async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "sellers/seller-1"), {
      businessName: "Private Seller",
      phone: "9999999999",
    });
  });

  await assertFails(getDoc(doc(env.unauthenticatedContext().firestore(), "sellers/seller-1")));
  await assertSucceeds(getDoc(doc(env.authenticatedContext("seller-1").firestore(), "sellers/seller-1")));
});

test("seller-owned offers can be created and toggled but are bounded", async () => {
  const db = env.authenticatedContext("seller-1").firestore();
  const offer = doc(db, "sellers/seller-1/offers/offer-1");

  await assertSucceeds(setDoc(offer, {
    title: "Local offer",
    details: "Limited-time discount",
    active: true,
    createdAt: new Date(),
  }));
  await assertSucceeds(updateDoc(offer, { active: false }));
  await assertFails(setDoc(doc(db, "sellers/another-seller/offers/offer-2"), {
    title: "Cross-seller write",
    details: "Should fail",
    active: true,
  }));
  await assertFails(setDoc(doc(db, "sellers/seller-1/offers/offer-3"), {
    title: "x".repeat(121),
    details: "Too long",
    active: true,
  }));
});

test("customer cannot edit protected account state but can update display profile", async () => {
  const db = env.authenticatedContext("customer-1").firestore();
  const customer = doc(db, "customers/customer-1");

  await assertSucceeds(setDoc(customer, {
    role: "customer",
    displayName: "Customer",
  }));
  await assertSucceeds(updateDoc(customer, { displayName: "Updated Name" }));
  await assertFails(updateDoc(customer, { accountStatus: "blocked" }));
  await assertFails(updateDoc(customer, { role: "admin" }));
  await assertFails(updateDoc(customer, { approvalStatus: "approved" }));
});

test("onboarding applicant cannot set or later change approval state", async () => {
  const db = env.authenticatedContext("applicant-1").firestore();
  const application = doc(db, "onboarding_requests/application-1");

  await assertFails(setDoc(doc(db, "onboarding_requests/application-approved-field"), {
    uid: "applicant-1",
    role: "delivery_partner",
    approved: true,
    status: "pending",
  }));
  await assertFails(setDoc(doc(db, "onboarding_requests/application-verified-field"), {
    uid: "applicant-1",
    role: "delivery_partner",
    verificationStatus: "approved",
    status: "pending",
  }));
  await assertFails(setDoc(application, {
    uid: "applicant-1",
    role: "delivery_partner",
    status: "approved",
    approvalStatus: "approved",
  }));

  await assertSucceeds(setDoc(application, {
    uid: "applicant-1",
    role: "delivery_partner",
    status: "pending",
    name: "Applicant",
  }));
  await assertFails(updateDoc(application, { status: "approved" }));
  await assertFails(updateDoc(application, { approvalStatus: "approved" }));
});

test("vehicle owner cannot transfer ownership or self-verify", async () => {
  const db = env.authenticatedContext("owner-1").firestore();
  const vehicle = doc(db, "vehicles/vehicle-1");

  await assertSucceeds(setDoc(vehicle, {
    ownerUid: "owner-1",
    status: "available",
    listingStatus: "active",
    available: true,
    verified: false,
  }));
  await assertSucceeds(updateDoc(vehicle, { available: false, status: "paused" }));
  await assertFails(updateDoc(vehicle, { ownerUid: "attacker-2" }));
  await assertFails(updateDoc(vehicle, { verified: true }));
});

test("customers can use their own travel favorites but not another user's", async () => {
  const alice = env.authenticatedContext("alice").firestore();
  const bob = env.authenticatedContext("bob").firestore();
  const favorite = doc(alice, "customers/alice/travelFavorites/prayagraj");

  await assertSucceeds(setDoc(favorite, {
    destination: "Prayagraj",
    createdAt: new Date(),
  }));
  await assertFails(getDoc(doc(bob, "customers/alice/travelFavorites/prayagraj")));
});


test("customer cannot create an already assigned or completed legacy ride", async () => {
  const db = env.authenticatedContext("customer-ride-1").firestore();

  await assertSucceeds(setDoc(doc(db, "rideBookings/ride-request-1"), {
    customerUid: "customer-ride-1",
    status: "searching",
    rideType: "bike",
    pickupAddress: "Pickup",
    destinationAddress: "Destination",
  }));

  await assertFails(setDoc(doc(db, "rideBookings/ride-assigned-at-create"), {
    customerUid: "customer-ride-1",
    status: "accepted",
    partnerUid: "partner-1",
    rideType: "bike",
  }));

  await assertFails(setDoc(doc(db, "rideBookings/ride-completed-at-create"), {
    customerUid: "customer-ride-1",
    status: "completed",
    rideType: "bike",
  }));
});

test("vehicle bookings must refer to the real vehicle owner and start unconfirmed", async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "vehicles/vehicle-1"), {
      ownerUid: "real-owner",
      status: "available",
      available: true,
    });
  });

  const customerDb = env.authenticatedContext("booking-customer").firestore();
  await assertSucceeds(setDoc(doc(customerDb, "vehicleBookings/valid-booking"), {
    vehicleId: "vehicle-1",
    ownerUid: "real-owner",
    ownerName: "Real owner",
    ownerPhone: "9999999999",
    customerUid: "booking-customer",
    customerName: "Customer",
    customerEmail: "customer@example.test",
    category: "car",
    listedPrice: 1200,
    mode: "book",
    status: "Booked",
    createdAt: new Date(),
  }));

  await assertFails(setDoc(doc(customerDb, "vehicleBookings/forged-owner"), {
    vehicleId: "vehicle-1",
    ownerUid: "attacker-owner",
    customerUid: "booking-customer",
    status: "Booked",
    createdAt: new Date(),
  }));

  await assertFails(setDoc(doc(customerDb, "vehicleBookings/preaccepted"), {
    vehicleId: "vehicle-1",
    ownerUid: "real-owner",
    customerUid: "booking-customer",
    status: "Accepted",
    createdAt: new Date(),
  }));
});

test("partners cannot self-enable shifts during registration", async () => {
  const driverDb = env.authenticatedContext("driver-self-enable").firestore();
  await assertFails(setDoc(doc(driverDb, "ridePartners/driver-self-enable"), {
    role: "carrier",
    approvalStatus: "pending",
    status: "online",
    shiftStatus: "off_duty",
    isOnline: true,
    availableForRides: true,
    locationTrackingActive: true,
  }));

  await assertSucceeds(setDoc(doc(driverDb, "ridePartners/driver-pending"), {
    role: "carrier",
    approvalStatus: "pending",
    status: "pending",
    shiftStatus: "off_duty",
    isOnline: false,
    availableForRides: false,
    availableForDeliveries: false,
  }));

  const deliveryDb = env.authenticatedContext("delivery-self-enable").firestore();
  await assertFails(setDoc(doc(deliveryDb, "deliveryPartners/delivery-self-enable"), {
    role: "delivery_partner",
    approvalStatus: "pending",
    status: "online",
    shiftStatus: "off_duty",
    isOnline: true,
    availableForDeliveries: true,
    locationTrackingActive: true,
  }));
});

test("service areas are readable but writable only by an administrator", async () => {
  const customerDb = env.authenticatedContext("ordinary-user").firestore();
  await assertSucceeds(getDoc(doc(customerDb, "serviceAreas/public-zone")));
  await assertFails(setDoc(doc(customerDb, "serviceAreas/forged-zone"), {
    name: "Forged zone",
    active: true,
  }));

  const adminDb = env.authenticatedContext("admin-user", {
    email: "mauryasujeet698@gmail.com",
  }).firestore();
  await assertSucceeds(setDoc(doc(adminDb, "serviceAreas/real-zone"), {
    name: "Pilot zone",
    active: true,
  }));
});

test("customers cannot create order documents or edit server-owned prices/payment status", async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "orders/server-priced-order"), {
      customerUid: "order-owner",
      status: "New Order",
      subtotal: 100,
      deliveryFee: 20,
      total: 120,
      paymentMethod: "COD",
      paymentStatus: "pending",
    });
  });

  const customerDb = env.authenticatedContext("order-owner").firestore();
  await assertFails(setDoc(doc(customerDb, "orders/forged-order"), {
    customerUid: "order-owner",
    status: "New Order",
    subtotal: 1,
    deliveryFee: 0,
    total: 1,
    paymentMethod: "COD",
    paymentStatus: "cash_collected",
  }));

  await assertFails(updateDoc(doc(customerDb, "orders/server-priced-order"), {
    total: 1,
    subtotal: 1,
  }));
  await assertFails(updateDoc(doc(customerDb, "orders/server-priced-order"), {
    paymentStatus: "paid",
  }));

  await assertSucceeds(updateDoc(doc(customerDb, "orders/server-priced-order"), {
    status: "Cancelled",
    cancellationReason: "Customer changed their mind",
    updatedAt: new Date(),
  }));
});

test("partners cannot change approval or online state directly after registration", async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "ridePartners/driver-status"), {
      role: "carrier",
      approvalStatus: "pending",
      status: "offline",
      shiftStatus: "off_duty",
      isOnline: false,
      availableForRides: false,
      activeRideId: null,
    });
    await setDoc(doc(ctx.firestore(), "deliveryPartners/delivery-status"), {
      role: "delivery_partner",
      approvalStatus: "pending",
      status: "offline",
      shiftStatus: "off_duty",
      isOnline: false,
      availableForDeliveries: false,
      currentOrderId: null,
    });
  });

  const driverDb = env.authenticatedContext("driver-status").firestore();
  await assertFails(updateDoc(doc(driverDb, "ridePartners/driver-status"), {
    status: "online",
    isOnline: true,
    availableForRides: true,
  }));
  await assertFails(updateDoc(doc(driverDb, "ridePartners/driver-status"), {
    approvalStatus: "approved",
  }));

  const deliveryDb = env.authenticatedContext("delivery-status").firestore();
  await assertFails(updateDoc(doc(deliveryDb, "deliveryPartners/delivery-status"), {
    status: "online",
    isOnline: true,
    availableForDeliveries: true,
  }));
});

test("privacy requests require ownership, valid type and submitted status", async () => {
  const ownerDb = env.authenticatedContext("privacy-owner").firestore();
  await assertSucceeds(setDoc(doc(ownerDb, "privacyRequests/request-valid"), {
    uid: "privacy-owner",
    requestType: "erasure",
    details: "Please delete my account and personal data.",
    status: "submitted",
    createdAt: new Date(),
    source: "android_app",
  }));

  await assertFails(setDoc(doc(ownerDb, "privacyRequests/request-forged-owner"), {
    uid: "someone-else",
    requestType: "erasure",
    details: "Please delete my account and personal data.",
    status: "submitted",
  }));
  await assertFails(setDoc(doc(ownerDb, "privacyRequests/request-pre-resolved"), {
    uid: "privacy-owner",
    requestType: "erasure",
    details: "Please delete my account and personal data.",
    status: "resolved",
  }));
  await assertFails(setDoc(doc(ownerDb, "privacyRequests/request-invalid-type"), {
    uid: "privacy-owner",
    requestType: "make-admin",
    details: "Please grant extra privileges to me.",
    status: "submitted",
  }));

  const otherDb = env.authenticatedContext("other-user").firestore();
  await assertFails(getDoc(doc(otherDb, "privacyRequests/request-valid")));
});
