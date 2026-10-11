#!/usr/bin/env node
"use strict";

const admin = require("firebase-admin");

async function main() {
  const raw = process.env.FIREBASE_SERVICE_ACCOUNT_JSON || "";
  if (!raw) throw new Error("Missing FIREBASE_SERVICE_ACCOUNT_JSON GitHub Actions secret.");
  const serviceAccount = JSON.parse(raw);
  const version = (process.env.APP_VERSION || "").trim();
  const docId = (process.env.APP_UPDATE_DOC || "").trim();
  const apkUrl = (process.env.APP_APK_URL || "").trim();
  const sha256 = (process.env.APK_SHA256 || "").trim().toLowerCase().replace(/^sha256:/, "");
  if (!version || !docId || !apkUrl.startsWith("https://")) {
    throw new Error("APP_VERSION, APP_UPDATE_DOC and a valid HTTPS APP_APK_URL are required.");
  }
  if (!/^[a-f0-9]{64}$/.test(sha256)) {
    throw new Error("APK_SHA256 must contain the 64-character SHA-256 digest of the exact released APK.");
  }
  admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
  try {
    await admin.firestore().collection("settings").doc(docId).set({
      version,
      apkUrl,
      sha256,
      notes: process.env.APP_UPDATE_NOTES || "Reliability, security and performance improvements.",
      mandatory: true,
      channel: "stable",
      updatedAt: admin.firestore.FieldValue.serverTimestamp()
    }, { merge: true });
    process.stdout.write("Published update manifest settings/" + docId + " for version " + version + "\n");
  } finally {
    await admin.app().delete();
  }
}

main().catch((error) => {
  process.stderr.write("Update manifest publish failed: " + (error.message || error) + "\n");
  process.exitCode = 1;
});
