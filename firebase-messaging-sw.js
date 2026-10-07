importScripts("https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js");
importScripts("https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js");

firebase.initializeApp({
  apiKey: "AIzaSyCopzTF-jwLnzcbCnW5Y9nIHYMkiinaZ28",
  authDomain: "allways-web.firebaseapp.com",
  projectId: "allways-web",
  storageBucket: "allways-web.firebasestorage.app",
  messagingSenderId: "869987297351",
  appId: "1:869987297351:web:fde91fb46194a141976962"
});

const messaging = firebase.messaging();
messaging.onBackgroundMessage((payload) => {
  const title = payload.notification?.title || payload.data?.title || "ALLways";
  const body = payload.notification?.body || payload.data?.body || payload.data?.message || "You have a new ALLways update.";
  self.registration.showNotification(title, {
    body,
    icon: "/favicon.ico",
    data: payload.data || {}
  });
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(clients.matchAll({type:"window",includeUncontrolled:true}).then((list) => {
    for (const client of list) {
      if ("focus" in client) return client.focus();
    }
    if (clients.openWindow) return clients.openWindow("/");
  }));
});