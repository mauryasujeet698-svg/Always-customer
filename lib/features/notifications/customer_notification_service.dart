import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CustomerNotificationService {
  StreamSubscription<String>? _tokenSubscription;
  String? _registeredUid;

  Future<void> registerForUser(User user) async {
    if (_registeredUid == user.uid) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('notifications_enabled') == false) return;

      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        await prefs.setBool('notifications_enabled', false);
        return;
      }

      await FirebaseMessaging.instance.subscribeToTopic('all_users');
      await FirebaseMessaging.instance.subscribeToTopic('customers');
      await _saveToken(user.uid, await FirebaseMessaging.instance.getToken());
      _registeredUid = user.uid;

      await _tokenSubscription?.cancel();
      _tokenSubscription = FirebaseMessaging.instance.onTokenRefresh.listen(
        (token) => _saveToken(user.uid, token),
      );
    } catch (_) {
      // Notification failure must not block sign-in or checkout.
    }
  }

  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notifications_enabled', enabled);
    if (!enabled) {
      await FirebaseMessaging.instance.unsubscribeFromTopic('customers');
      await FirebaseMessaging.instance.unsubscribeFromTopic('all_users');
      await _tokenSubscription?.cancel();
      _tokenSubscription = null;
      _registeredUid = null;
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final token = await FirebaseMessaging.instance.getToken();
        if (token != null && token.isNotEmpty) {
          await FirebaseFirestore.instance
              .collection('fcmTokens')
              .doc(user.uid)
              .collection('tokens')
              .doc(token)
              .delete()
              .catchError((_) {});
        }
      }
    } else {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) await registerForUser(user);
    }
  }

  Future<void> _saveToken(String uid, String? token) async {
    if (token == null || token.isEmpty) return;
    await FirebaseFirestore.instance
        .collection('fcmTokens')
        .doc(uid)
        .collection('tokens')
        .doc(token)
        .set({
          'uid': uid,
          'token': token,
          'role': 'customer',
          'platform': 'android',
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  }

  Future<void> dispose() async {
    await _tokenSubscription?.cancel();
    _tokenSubscription = null;
  }
}
