import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/product_repository.dart';
import '../domain/product.dart';

final productRepositoryProvider = Provider<ProductRepository>(
  (ref) => ProductRepository(FirebaseFirestore.instance),
);

final productsProvider = FutureProvider<List<Product>>(
  (ref) => ref.watch(productRepositoryProvider).fetchProducts(),
);
