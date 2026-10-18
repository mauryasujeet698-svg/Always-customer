import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/product.dart';

class ProductRepository {
  ProductRepository(this._firestore);

  final FirebaseFirestore _firestore;

  Future<List<Product>> fetchProducts() async {
    final snapshot = await _firestore
        .collection('products')
        .get(const GetOptions(source: Source.serverAndCache));
    final products = snapshot.docs
        .map((doc) => Product.fromMap(doc.id, doc.data()))
        .where((product) => product.name.isNotEmpty)
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return products;
  }
}
