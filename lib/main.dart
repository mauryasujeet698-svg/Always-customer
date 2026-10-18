import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'app/allways_app.dart';
import 'map_tile_cache.dart';

@pragma('vm:entry-point')
Future<void> allwaysFirebaseMessagingBackgroundHandler(
  RemoteMessage message,
) async {
  await Firebase.initializeApp();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeAllwaysCustomerMapTileCache();

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(
    allwaysFirebaseMessagingBackgroundHandler,
  );

  // Provider setup must not prevent phone/email sign-in if Google is not
  // configured on a particular device.
  try {
    await GoogleSignIn.instance.initialize();
  } catch (_) {}

  runApp(const ProviderScope(child: AllwaysCustomerApp()));
}
