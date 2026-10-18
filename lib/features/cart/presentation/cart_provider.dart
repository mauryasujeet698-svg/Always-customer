import 'package:flutter_riverpod/flutter_riverpod.dart';

final cartProvider = NotifierProvider<CartController, Map<String, int>>(
  CartController.new,
);

class CartController extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() => const {};

  void add(String productId, {int maximum = 99}) {
    final next = Map<String, int>.from(state);
    next[productId] = ((next[productId] ?? 0) + 1).clamp(1, maximum);
    state = Map.unmodifiable(next);
  }

  void decrement(String productId) {
    final next = Map<String, int>.from(state);
    final current = next[productId] ?? 0;
    if (current <= 1) {
      next.remove(productId);
    } else {
      next[productId] = current - 1;
    }
    state = Map.unmodifiable(next);
  }

  void remove(String productId) {
    final next = Map<String, int>.from(state)..remove(productId);
    state = Map.unmodifiable(next);
  }

  void clear() => state = const {};
}
