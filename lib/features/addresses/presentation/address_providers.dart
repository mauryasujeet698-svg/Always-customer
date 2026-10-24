import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/saved_address_repository.dart';
import '../domain/saved_address.dart';

final savedAddressRepositoryProvider = Provider<SavedAddressRepository>(
  (ref) => SavedAddressRepository(),
);

final savedAddressesProvider =
    FutureProvider.family<List<SavedAddress>, String>(
  (ref, uid) => ref.watch(savedAddressRepositoryProvider).load(uid),
);
