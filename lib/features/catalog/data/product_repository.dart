import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;

import '../domain/product.dart';

class ProductRepository {
  ProductRepository(this._firestore, {http.Client? client})
      : _client = client ?? http.Client();

  final FirebaseFirestore _firestore;
  final http.Client _client;

  // Existing customer website used this Apps Script URL when the Firestore
  // catalog was empty. Keep it as a compatibility fallback during migration.
  static const _catalogFallbackUrl =
      'https://script.google.com/macros/s/AKfycbxnmGS7Q6t7pPWiT50V87JmA0Qbh2tSi1UKLFzN28dQpybjw7vvCufnryi-qpTnq0b0IA/exec';

  Future<List<Product>> fetchProducts() async {
    try {
      final snapshot = await _firestore
          .collection('products')
          .get(const GetOptions(source: Source.serverAndCache));
      final products = snapshot.docs
          .map((doc) => Product.fromMap(doc.id, doc.data()))
          .where((product) => product.name.isNotEmpty)
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (products.isNotEmpty) return products;
    } catch (_) {
      // Try the existing catalog endpoint if Firestore is unavailable.
    }

    final response = await _client
        .get(Uri.parse(_catalogFallbackUrl))
        .timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Catalog request failed with HTTP ${response.statusCode}.');
    }
    final decoded = jsonDecode(response.body);
    final dynamic entries = decoded is Map ? decoded['products'] : decoded;
    if (entries is! List) {
      throw const FormatException('Catalog response is not a product list.');
    }
    final products = <Product>[];
    for (final entry in entries) {
      if (entry is Map) {
        final data = Map<String, dynamic>.from(entry);
        final fallbackId = (data['ID'] ?? data['id'] ?? '').toString();
        final product = Product.fromMap(fallbackId, data);
        if (product.name.isNotEmpty) products.add(product);
      }
    }
    products.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return products;
  }
}
