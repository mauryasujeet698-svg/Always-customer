const {onDocumentWritten} = require("firebase-functions/v2/firestore");
const {getMessaging} = require("firebase-admin/messaging");

const TOPICS_BY_ROLE = Object.freeze({
  admin: ["all_users", "admins"],
  delivery_partner: ["all_users", "delivery_partners"],
  carrier: ["all_users", "carriers"],
  ride_partner: ["all_users", "carriers"],
  driver: ["all_users", "carriers"],
  customer: ["all_users", "customers"],
});

exports.syncFcmTokenTopics = onDocumentWritten(
  "fcmTokens/{uid}/tokens/{tokenId}",
  async (event) => {
    const after = event.data && event.data.after;
    if (!after || !after.exists) return;

    const data = after.data() || {};
    const uid = event.params.uid;
    const tokenId = event.params.tokenId;
    const role = String(data.role || "").trim().toLowerCase();
    const token = String(data.token || "").trim();
    const topics = TOPICS_BY_ROLE[role];

    if (!token) {
      console.warn("Skipping FCM topic sync: token missing", {uid, tokenId});
      return;
    }
    if (!topics) {
      console.warn("Skipping FCM topic sync: unsupported role", {uid, tokenId, role});
      return;
    }

    await Promise.all(topics.map(async (topic) => {
      try {
        await getMessaging().subscribeToTopic(token, topic);
        console.info("FCM token subscribed to topic", {uid, tokenId, topic, role});
      } catch (error) {
        console.error("FCM topic subscription failed", {
          uid, tokenId, topic, role,
          error: error && error.message ? error.message : String(error),
        });
      }
    }));
  }
);
