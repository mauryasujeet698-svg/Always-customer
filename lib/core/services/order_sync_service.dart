import 'dart:convert';

import 'package:http/http.dart' as http;

import '../constants/backend_constants.dart';

Future<void> syncOrderToGoogleAppsScript(
  Map<String, dynamic> order, {
  http.Client? client,
}) async {
  final httpClient = client ?? http.Client();
  try {
    await httpClient
        .post(
          Uri.parse(BackendConstants.orderEndpoint),
          headers: const {'Content-Type': 'text/plain;charset=utf-8'},
          body: jsonEncode(order),
        )
        .timeout(const Duration(seconds: 8));
  } catch (_) {
    // Firestore is the source of truth. A Sheets sync outage must not lose
    // or falsely fail an order already saved in Firestore.
  } finally {
    if (client == null) httpClient.close();
  }
}
