import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/saved_address.dart';

class SavedAddressRepository {
  Future<List<SavedAddress>> load(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('allwaysAddresses_$uid');
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((item) => SavedAddress.fromMap(Map<String, dynamic>.from(item)))
          .where((item) => item.id.isNotEmpty && item.address.isNotEmpty)
          .take(5)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(String uid, List<SavedAddress> addresses) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'allwaysAddresses_$uid',
      jsonEncode(addresses.take(5).map((item) => item.toMap()).toList()),
    );
  }

  Future<void> upsert({
    required String uid,
    required String name,
    required String phone,
    required String address,
  }) async {
    final list = (await load(uid)).toList();
    final normalized = address.trim().toLowerCase();
    list.removeWhere((item) => item.address.trim().toLowerCase() == normalized);
    list.insert(0, SavedAddress(
      id: 'ADDR${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim(),
      phone: phone.trim(),
      address: address.trim(),
    ));
    await save(uid, list);
  }

  Future<void> delete(String uid, String id) async {
    final list = (await load(uid)).where((item) => item.id != id).toList();
    await save(uid, list);
  }
}
