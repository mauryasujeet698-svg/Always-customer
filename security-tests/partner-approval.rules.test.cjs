const fs = require("node:fs");
const path = require("node:path");
const { after, before, test } = require("node:test");
const { assertFails, assertSucceeds, initializeTestEnvironment } = require("@firebase/rules-unit-testing");
const { doc, setDoc, updateDoc } = require("firebase/firestore");

const rules = fs.readFileSync(path.join(__dirname, "../firestore.rules"), "utf8");
const adminEmail = "mauryasujeet698@gmail.com";
let env;

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-allways-approval-test",
    firestore: { rules },
  });
  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, "deliveryPartners/delivery-1"), { approvalStatus: "pending", displayName: "Driver" });
    await setDoc(doc(db, "ridePartners/ride-1"), { approvalStatus: "pending", displayName: "Ride partner" });
  });
});

after(async () => {
  if (env) await env.cleanup();
});

for (const collection of ["deliveryPartners", "ridePartners"]) {
  test(`${collection}: owner may create a pending profile but cannot self-approve`, async () => {
    const db = env.authenticatedContext("owner-1").firestore();
    await assertSucceeds(setDoc(doc(db, `${collection}/owner-1`), { approvalStatus: "pending" }));
    const selfApprovingDb = env.authenticatedContext("owner-2").firestore();
    await assertFails(setDoc(doc(selfApprovingDb, `${collection}/owner-2`), { approvalStatus: "approved" }));
  });

  test(`${collection}: owner may edit ordinary fields but cannot change approvalStatus`, async () => {
    const db = env.authenticatedContext(collection === "deliveryPartners" ? "delivery-1" : "ride-1").firestore();
    const id = collection === "deliveryPartners" ? "delivery-1" : "ride-1";
    await assertSucceeds(updateDoc(doc(db, `${collection}/${id}`), { displayName: "Updated name" }));
    await assertFails(updateDoc(doc(db, `${collection}/${id}`), { approvalStatus: "approved" }));
  });

  test(`${collection}: admin can change approvalStatus`, async () => {
    const id = collection === "deliveryPartners" ? "delivery-1" : "ride-1";
    const db = env.authenticatedContext("admin-1", { email: adminEmail }).firestore();
    await assertSucceeds(updateDoc(doc(db, `${collection}/${id}`), { approvalStatus: "approved" }));
  });
}
