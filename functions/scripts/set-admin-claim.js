#!/usr/bin/env node
"use strict";

const {applicationDefault, initializeApp} = require("firebase-admin/app");
const {getAuth} = require("firebase-admin/auth");

async function main() {
  const uid = String(process.argv[2] || "").trim();
  const projectId = String(process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || "").trim();
  if (!uid) {
    throw new Error("Usage: GCLOUD_PROJECT=<project-id> node functions/scripts/set-admin-claim.js <firebase-auth-uid>");
  }
  if (!projectId) {
    throw new Error("Set GCLOUD_PROJECT or GOOGLE_CLOUD_PROJECT explicitly. Refusing to guess the Firebase project.");
  }

  initializeApp({credential: applicationDefault(), projectId});
  const auth = getAuth();
  const user = await auth.getUser(uid);
  await auth.setCustomUserClaims(uid, {...(user.customClaims || {}), admin: true});
  console.log("Admin claim assigned to UID:", uid);
  console.log("The account must refresh its Firebase ID token or sign in again before Firestore Rules see the claim.");
}

main().catch((error) => {
  console.error(error.message || error);
  process.exitCode = 1;
});
