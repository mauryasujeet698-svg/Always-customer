class Product {
  const Product({
    required this.id,
    required this.name,
    required this.category,
    required this.price,
    required this.stock,
    required this.available,
    this.imageUrl = '',
    this.emoji = '🛒',
    this.description = '',
    this.brand = '',
    this.maxQty = 10,
  });

  final String id;
  final String name;
  final String category;
  final double price;
  final int stock;
  final bool available;
  final String imageUrl;
  final String emoji;
  final String description;
  final String brand;
  final int maxQty;

  factory Product.fromMap(String id, Map<String, dynamic> data) {
    final availableRaw = data['available'] ?? data['Available'] ?? true;
    final available = availableRaw is bool
        ? availableRaw
        : !{'no', 'false', '0', 'unavailable'}.contains(
            availableRaw.toString().trim().toLowerCase(),
          );
    final stock = _asInt(data['stock'] ?? data['Stock']);
    return Product(
      id: (data['id'] ?? data['ID'] ?? id).toString(),
      name: (data['name'] ?? data['title'] ?? data['Product Name'] ?? '')
          .toString()
          .trim(),
      category: (data['category'] ?? data['cat'] ?? data['Category'] ?? 'Other')
          .toString()
          .trim(),
      price: _asDouble(data['price'] ?? data['Price']),
      stock: available ? stock : 0,
      available: available,
      imageUrl: (data['imageUrl'] ?? data['imageURL'] ?? data['Image URL'] ?? '')
          .toString()
          .trim(),
      emoji: (data['emoji'] ?? data['icon'] ?? data['Emoji'] ?? '🛒')
          .toString(),
      description: (data['description'] ?? data['Description'] ?? '').toString(),
      brand: (data['brand'] ?? data['Brand'] ?? '').toString(),
      maxQty: _asInt(data['maxQty'] ?? data['Max Qty'], fallback: 10).clamp(1, 99).toInt(),
    );
  }

  static int _asInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }
}
