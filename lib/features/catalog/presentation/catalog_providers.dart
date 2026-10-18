import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../data/product_repository.dart';
import '../domain/product.dart';

final productHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

final productRepositoryProvider = Provider<ProductRepository>(
  (ref) => ProductRepository(
    FirebaseFirestore.instance,
    client: ref.watch(productHttpClientProvider),
  ),
);

final productsProvider = FutureProvider<List<Product>>(
  (ref) => ref.watch(productRepositoryProvider).fetchProducts(),
);
