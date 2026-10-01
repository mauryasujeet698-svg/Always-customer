const {setGlobalOptions} = require("firebase-functions/v2");
const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {initializeApp} = require("firebase-admin/app");
const {getMessaging} = require("firebase-admin/messaging");

initializeApp();

setGlobalOptions({
  region: "asia-south1",
  maxInstances: 10,
});

const ALLOWED_TOPICS = new Set([
  "all_users",
  "admins",
  "carriers",
  "delivery_partners",
  "customers",
]);

exports.sendAnnouncement = onDocumentCreated(
  "announcements/{announcementId}",
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) return;

    const data = snapshot.data() || {};
    if (data.status === "sent") return;

    const topic = String(
      data.topic || data.targetAudience || "all_users"
    ).trim();

    if (!ALLOWED_TOPICS.has(topic)) {
      await snapshot.ref.update({
        status: "failed",
        error: "Invalid notification topic",
      });
      return;
    }

    const title = String(data.title || "ALLways").trim();
    const body = String(data.body || "").trim();

    try {
      await getMessaging().send({
        topic,
        notification: {
          title,
          body,
        },
        data: {
          announcementId: event.params.announcementId,
          type: String(data.type || "announcement"),
          topic,
        },
      });

      await snapshot.ref.update({
        status: "sent",
        sentAt: new Date(),
      });
    } catch (error) {
      console.error("ALLways announcement notification failed:", error);
      await snapshot.ref.update({
        status: "failed",
        error: String(error && error.message ? error.message : error),
      });
      throw error;
    }
  }
);
