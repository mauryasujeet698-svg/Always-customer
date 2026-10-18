class SavedAddress {
  const SavedAddress({
    required this.id,
    required this.name,
    required this.phone,
    required this.address,
  });

  final String id;
  final String name;
  final String phone;
  final String address;

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'phone': phone,
    'address': address,
  };

  factory SavedAddress.fromMap(Map<String, dynamic> map) => SavedAddress(
    id: (map['id'] ?? '').toString(),
    name: (map['name'] ?? '').toString(),
    phone: (map['phone'] ?? '').toString(),
    address: (map['address'] ?? '').toString(),
  );
}
