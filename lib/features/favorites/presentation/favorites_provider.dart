import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../auth/presentation/auth_providers.dart';

final favoriteIdsProvider =
    AsyncNotifierProvider<FavoritesController, Set<String>>(
  FavoritesController.new,
);

class FavoritesController extends AsyncNotifier<Set<String>> {
  @override
  Future<Set<String>> build() async {
    final user = ref.watch(authStateProvider).asData?.value;
    if (user == null) return const <String>{};

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('allwaysFavourites_${user.uid}');
    if (raw == null || raw.isEmpty) return const <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <String>{};
      return Set.unmodifiable(decoded.map((item) => item.toString()));
    } catch (_) {
      return const <String>{};
    }
  }

  Future<void> toggle(String productId) async {
    final user = ref.read(authStateProvider).asData?.value;
    if (user == null) {
      throw StateError('Sign in to save favourite products.');
    }

    final next = Set<String>.from(state.asData?.value ?? const <String>{});
    if (!next.add(productId)) next.remove(productId);
    final immutable = Set<String>.unmodifiable(next);
    state = AsyncData(immutable);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'allwaysFavourites_${user.uid}',
      jsonEncode(immutable.toList()),
    );
  }

  bool isFavorite(String productId) =>
      (state.asData?.value ?? const <String>{}).contains(productId);
}
