import 'dart:io';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cache/flutter_map_cache.dart';
import 'package:http_cache_file_store/http_cache_file_store.dart';
import 'package:path_provider/path_provider.dart';

/// Shared persistent map tile cache for customer map screens.
TileProvider allwaysCustomerMapTileProvider = NetworkTileProvider();

Future<void> initializeAllwaysCustomerMapTileCache() async {
  try {
    final directory = await getTemporaryDirectory();
    final store = FileCacheStore(
      directory.path + Platform.pathSeparator + 'allways_customer_map_tiles',
    );
    allwaysCustomerMapTileProvider = CachedTileProvider(
      store: store,
      maxStale: const Duration(days: 30),
    );
  } catch (_) {
    allwaysCustomerMapTileProvider = NetworkTileProvider();
  }
}
