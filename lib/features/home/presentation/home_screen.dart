import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../cart/presentation/cart_provider.dart';
import '../../favorites/presentation/favorites_provider.dart';
import '../../catalog/domain/product.dart';
import '../../catalog/presentation/catalog_providers.dart';
import '../../orders/presentation/orders_screen.dart';
import '../../profile/presentation/profile_screen.dart';
import '../../../map_tile_cache.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _selectedTab = 0;
  String _query = '';
  bool _showWelcomeCard = true;
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(cartProvider);
    final products = ref.watch(productsProvider).asData?.value ?? const <Product>[];
    final cartCount = cart.values.fold<int>(0, (total, quantity) => total + quantity);
    final subtotal = products.fold<double>(0, (total, product) {
      return total + product.price * (cart[product.id] ?? 0);
    });
    final auth = ref.watch(authStateProvider).asData?.value;

    return Scaffold(
      appBar: (_selectedTab == 1 || _selectedTab == 2) ? null : AppBar(
        toolbarHeight: 76,
        titleSpacing: 18,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text.rich(
              TextSpan(children: [
                TextSpan(text: 'ALL', style: TextStyle(color: AllwaysTheme.purple)),
                TextSpan(text: 'ways', style: TextStyle(color: AllwaysTheme.ink)),
              ]),
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 27, letterSpacing: -1.0),
            ),
            Text('Everything you need, delivered locally.',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade700, fontWeight: FontWeight.w500)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Food Corner',
            onPressed: () => setState(() => _selectedTab = 3),
            icon: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text('🍔', style: TextStyle(fontSize: 22)),
              Text('Food Corner', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700)),
            ]),
          ),
          IconButton(
            tooltip: 'Favourites',
            onPressed: () {
              if (auth == null) { context.push('/login'); }
              else { setState(() { _selectedTab = 0; }); }
            },
            icon: const Icon(Icons.favorite_border_rounded),
          ),
          IconButton(
            tooltip: 'Cart',
            onPressed: () => context.push('/checkout'),
            icon: const Icon(Icons.shopping_cart_outlined),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: IndexedStack(
        index: _selectedTab,
        children: [
          Column(
            children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF7FA),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AllwaysTheme.line),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(children: [
                    const Icon(Icons.location_on_rounded, size: 22, color: AllwaysTheme.green),
                    const SizedBox(width: 8),
                    const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Deliver to', style: TextStyle(fontSize: 10, color: Colors.grey)),
                      Text('Choose delivery location', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700)),
                    ])),
                    TextButton(
                      onPressed: () => setState(() => _selectedTab = 2),
                      child: const Text('Change'),
                    ),
                  ]),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _searchController,
                  onChanged: (value) => setState(() => _query = value.trim().toLowerCase()),
                  decoration: InputDecoration(
                    hintText: 'Search food, groceries and more...',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _query.isEmpty ? IconButton(tooltip: 'Voice search', onPressed: () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Voice search is not available yet.'))), icon: const Icon(Icons.mic_none_rounded)) : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ],
            ),
          ),
          if (_showWelcomeCard)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Dismissible(
                key: const ValueKey('allways-welcome-card'),
                direction: DismissDirection.horizontal,
                onDismissed: (_) => setState(() => _showWelcomeCard = false),
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(22), border: Border.all(color: AllwaysTheme.line.withValues(alpha: 0.65))),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  child: Row(children: [
                    Container(width: 42, height: 42, decoration: const BoxDecoration(color: AllwaysTheme.blush, shape: BoxShape.circle), child: const Icon(Icons.local_offer_outlined, color: AllwaysTheme.green, size: 23)),
                    const SizedBox(width: 14),
                    const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Welcome back', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      SizedBox(height: 3),
                      Text("We're ready", style: TextStyle(color: Colors.grey, fontSize: 13)),
                    ])),
                  ]),
                ),
              ),
            ),
          const SizedBox(height: 10),

              Expanded(
                child: ShopTab(searchQuery: _query, showBanner: true),
              ),
            ],
          ),
          const TravelTab(),
          const ProfileScreen(),
          const FoodTab(),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 5, 12, 8),
        child: Container(decoration: BoxDecoration(color: Theme.of(context).cardColor.withValues(alpha: 0.97), borderRadius: BorderRadius.circular(28), border: Border.all(color: AllwaysTheme.line), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 14, offset: const Offset(0, -3))]), padding: const EdgeInsets.all(5), child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (cartCount > 0 && (_selectedTab == 0 || _selectedTab == 3)) Container(margin: const EdgeInsets.only(bottom: 5), decoration: BoxDecoration(color: const Color(0xFF8E174F), borderRadius: BorderRadius.circular(18)), padding: const EdgeInsets.fromLTRB(14, 8, 8, 8), child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [Text('$cartCount item${cartCount == 1 ? "" : "s"}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)), Text('₹${subtotal.toStringAsFixed(0)} subtotal', style: const TextStyle(color: Color(0xFFF4C8DC)))])),
            FilledButton(style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE65C91), foregroundColor: Colors.white), onPressed: () => context.push('/checkout'), child: const Text('View cart →')),
          ])),
          Row(children: [
            _BottomNavItem(icon: Icons.shopping_bag_outlined, label: 'Shop', selected: _selectedTab == 0, onTap: () => setState(() => _selectedTab = 0)),
            _BottomNavItem(icon: Icons.directions_bus_outlined, label: 'Travel', selected: _selectedTab == 1, onTap: () => setState(() => _selectedTab = 1)),
            _BottomNavItem(icon: Icons.person_outline_rounded, label: 'Profile', selected: _selectedTab == 2, onTap: () => setState(() => _selectedTab = 2)),
          ]),
        ])),
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  const _BottomNavItem({required this.icon, required this.label, required this.selected, required this.onTap});
  final IconData icon; final String label; final bool selected; final VoidCallback onTap;
  @override Widget build(BuildContext context) => Expanded(child: Material(color: selected ? const Color(0xFFFFD9E5) : Colors.transparent, borderRadius: BorderRadius.circular(22), child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(22), child: Padding(padding: const EdgeInsets.symmetric(vertical: 9), child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon, color: const Color(0xFF6E4053), size: 23), const SizedBox(height: 3), Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF6E4053), fontWeight: FontWeight.w600))])))));
}
class _ShopBanner extends StatelessWidget {
  const _ShopBanner();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('settings').doc('banners').snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data() ?? const <String, dynamic>{};
        final title = (data['title'] ?? data['heroTitle'] ?? 'Closer to You, Always').toString();
        final subtitle = (data['subtitle'] ?? data['deliveryText'] ?? 'Fast local delivery').toString();
        final raw = data['imageUrls'] ?? data['banners'] ?? data['items'];
        final urls = raw is List
            ? raw.map((item) {
                if (item is Map) return (item['imageUrl'] ?? item['image'] ?? item['url'] ?? '').toString();
                return item.toString();
              }).where((url) => url.startsWith('http')).toList()
            : <String>[];
        return SizedBox(
          height: 150,
          width: double.infinity,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: urls.isNotEmpty
                ? PageView.builder(
                    itemCount: urls.length,
                    itemBuilder: (context, index) => Stack(
                      fit: StackFit.expand,
                      children: [
                        CachedNetworkImage(
                          imageUrl: urls[index],
                          fit: BoxFit.cover,
                          placeholder: (_, _) => const ColoredBox(color: Color(0xFFF9DCE8)),
                          errorWidget: (_, _, _) => const ColoredBox(
                            color: Color(0xFF8D174F),
                            child: Icon(Icons.image_not_supported_outlined, color: Colors.white),
                          ),
                        ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Colors.black.withValues(alpha: 0.55)],
                            ),
                          ),
                        ),
                        Positioned(
                          left: 16,
                          right: 16,
                          bottom: 14,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800)),
                              const SizedBox(height: 4),
                              Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontSize: 13)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )
                : Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFF8D174F), Color(0xFFE65C91)],
                        begin: Alignment.bottomLeft,
                        end: Alignment.topRight,
                      ),
                    ),
                    child: Stack(
                      children: [
                        Positioned(right: 12, top: 8,
                          child: Icon(Icons.shopping_bag_outlined, size: 100, color: Colors.white.withValues(alpha: 0.17))),
                        Positioned(
                          left: 16, right: 16, bottom: 14,
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 4),
                            Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontSize: 13)),
                          ]),
                        ),
                      ],
                    ),
                  ),
          ),
        );
      },
    );
  }
}

class ShopTab extends ConsumerStatefulWidget {
  const ShopTab({required this.searchQuery, this.showBanner = false, super.key});
  final String searchQuery;
  final bool showBanner;

  @override
  ConsumerState<ShopTab> createState() => _ShopTabState();
}

class _ShopTabState extends ConsumerState<ShopTab> {
  String _category = 'All';
  bool _favoritesOnly = false;

  @override
  Widget build(BuildContext context) {
    final productsAsync = ref.watch(productsProvider);
    final cart = ref.watch(cartProvider);
    return productsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off_outlined, size: 42),
            const SizedBox(height: 10),
            const Text('Could not load items. Check your connection and retry.', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => ref.invalidate(productsProvider),
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ]),
        ),
      ),
      data: (allProducts) {
        final categories = allProducts.map((p) => p.category).where((c) => c.isNotEmpty).toSet().toList()..sort();
        categories.insert(0, 'All');
        final filtered = allProducts.where((p) {
          final categoryMatch = _category == 'All' || p.category == _category;
          final favoriteIds = ref.watch(favoriteIdsProvider).asData?.value ?? const <String>{};
          final favoriteMatch = !_favoritesOnly || favoriteIds.contains(p.id);
          final queryMatch = widget.searchQuery.isEmpty ||
              p.name.toLowerCase().contains(widget.searchQuery) ||
              p.category.toLowerCase().contains(widget.searchQuery) ||
              p.brand.toLowerCase().contains(widget.searchQuery) ||
              p.description.toLowerCase().contains(widget.searchQuery);
          return categoryMatch && favoriteMatch && queryMatch;
        }).toList();

        return RefreshIndicator(
          onRefresh: () => ref.refresh(productsProvider.future),
          child: ListView(
            key: const PageStorageKey<String>('customer-shop-scroll'),
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
            children: [
              if (widget.showBanner) ...[
                const _ShopBanner(),
                const SizedBox(height: 14),
              ],
              Row(
                children: [
                  const Expanded(child: Text('Categories', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900))),
                  Text('${allProducts.length} items', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 42,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: categories.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final category = categories[index];
                    final selected = _category == category;
                    return ChoiceChip(
                      label: Text(category),
                      selected: selected,
                      onSelected: (_) => setState(() => _category = category),
                      selectedColor: const Color(0xFFFFE1EC),
                      side: BorderSide(color: selected ? const Color(0xFFE8A7C4) : AllwaysTheme.line),
                      labelStyle: TextStyle(color: selected ? AllwaysTheme.green : null, fontWeight: selected ? FontWeight.w800 : FontWeight.w500),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(color: const Color(0xFFFFE1EC), borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.all(12),
                child: const Text('🚚  FREE DELIVERY on orders above ₹499 · ₹30 below ₹499', style: TextStyle(color: AllwaysTheme.green, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: Text(_favoritesOnly ? 'Saved favourites' : 'All items', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900))),
                IconButton(
                  tooltip: _favoritesOnly ? 'Show all items' : 'Show saved favourites',
                  onPressed: () {
                    final user = FirebaseAuth.instance.currentUser;
                    if (user == null) {
                      context.push('/login');
                    } else {
                      setState(() => _favoritesOnly = !_favoritesOnly);
                    }
                  },
                  icon: Icon(_favoritesOnly ? Icons.favorite : Icons.favorite_border, color: _favoritesOnly ? Colors.red : null),
                ),
                Text('${filtered.length} found', style: const TextStyle(color: Colors.grey, fontSize: 12)),
              ]),
              const SizedBox(height: 8),
              if (filtered.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: Text('No items match this search yet.')),
                )
              else
                LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 650 ? 4 : 2;
                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: filtered.length,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                        childAspectRatio: 0.63,
                      ),
                      itemBuilder: (context, index) => ProductCard(
                        product: filtered[index],
                        quantity: cart[filtered[index].id] ?? 0,
                      ),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

class ProductCard extends ConsumerWidget {
  const ProductCard({required this.product, required this.quantity, super.key});
  final Product product;
  final int quantity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unavailable = !product.available || product.stock <= 0;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SizedBox(
                width: double.infinity,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      product.imageUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: product.imageUrl,
                              fit: BoxFit.cover,
                              memCacheHeight: 320,
                              placeholder: (_, _) => Container(
                                color: const Color(0xFFFFF1F6),
                                alignment: Alignment.center,
                                child: const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
                              ),
                              errorWidget: (_, _, _) => _ProductPlaceholder(emoji: product.emoji),
                            )
                          : _ProductPlaceholder(emoji: product.emoji),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Material(
                          color: Colors.white.withValues(alpha: 0.94),
                          shape: const CircleBorder(),
                          child: Consumer(
                            builder: (context, ref, _) {
                              final favorites = ref.watch(favoriteIdsProvider).asData?.value ?? const <String>{};
                              final isFavorite = favorites.contains(product.id);
                              return IconButton(
                                iconSize: 20,
                                visualDensity: VisualDensity.compact,
                                tooltip: isFavorite ? 'Remove favourite' : 'Save favourite',
                                onPressed: () {
                                  if (FirebaseAuth.instance.currentUser == null) {
                                    context.push('/login');
                                    return;
                                  }
                                  ref.read(favoriteIdsProvider.notifier).toggle(product.id).catchError((_) {});
                                },
                                icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_border, color: isFavorite ? Colors.red : Colors.black87),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(product.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
            if (product.brand.isNotEmpty)
              Text(product.brand, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.grey, fontSize: 11)),
            const SizedBox(height: 4),
            Text('₹${product.price.toStringAsFixed(product.price % 1 == 0 ? 0 : 2)}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
            const SizedBox(height: 2),
            Text(unavailable ? 'Currently unavailable' : '${product.stock} available', style: TextStyle(fontSize: 11, color: unavailable ? Colors.grey : AllwaysTheme.green)),
            const SizedBox(height: 6),
            if (quantity == 0)
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: unavailable ? null : () => ref.read(cartProvider.notifier).add(product.id, maximum: product.maxQty),
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 8)),
                  child: const Text('ADD'),
                ),
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => ref.read(cartProvider.notifier).decrement(product.id),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Text('$quantity', style: const TextStyle(fontWeight: FontWeight.w900)),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: unavailable || quantity >= product.maxQty ? null : () => ref.read(cartProvider.notifier).add(product.id, maximum: product.maxQty),
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ProductPlaceholder extends StatelessWidget {
  const _ProductPlaceholder({required this.emoji});
  final String emoji;
  @override
  Widget build(BuildContext context) => Container(
    color: const Color(0xFFF0F5F1),
    alignment: Alignment.center,
    child: Text(emoji, style: const TextStyle(fontSize: 42)),
  );
}

class FoodTab extends StatelessWidget {
  const FoodTab({super.key});
  @override
  Widget build(BuildContext context) => const _ServiceLanding(
    icon: Icons.restaurant_outlined,
    title: 'ALLways Food',
    description: 'Local food ordering will appear here as restaurants are onboarded in your area.',
    label: 'Restaurant ordering is not available yet',
  );
}

class TravelTab extends StatefulWidget {
  const TravelTab({super.key});

  @override
  State<TravelTab> createState() => _TravelTabState();
}

class _TravelTabState extends State<TravelTab> {
  final _destinationController = TextEditingController();
  late final MapController _mapController;
  LatLng _center = const LatLng(25.45, 81.85);
  String _vehicle = 'bike';
  bool _locating = false;
  bool _hasCurrentLocation = false;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
  }

  @override
  void dispose() {
    _destinationController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _useCurrentLocation() async {
    if (_locating) return;
    setState(() => _locating = true);
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw StateError('Turn on location services to set your pickup point.');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError('Allow location permission to use your current pickup point.');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (!mounted) return;
      setState(() {
        _center = LatLng(position.latitude, position.longitude);
        _hasCurrentLocation = true;
      });
      _mapController.move(_center, 15);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString().replaceFirst('Bad state: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _continueToBooking() {
    final destination = _destinationController.text.trim();
    if (destination.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter where you want to go first.')),
      );
      return;
    }
    context.push(Uri(
      path: '/ride',
      queryParameters: {'vehicle': _vehicle, 'destination': destination},
    ).toString());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          flex: 5,
          child: Stack(
            children: [
              FlutterMap(
                key: const PageStorageKey<String>('customer-travel-home-map'),
                mapController: _mapController,
                options: MapOptions(initialCenter: _center, initialZoom: 14),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.allways.app',
                    maxZoom: 19,
                    tileProvider: allwaysCustomerMapTileProvider,
                  ),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: _center,
                        width: 46,
                        height: 54,
                        child: const Icon(
                          Icons.location_on_rounded,
                          color: AllwaysTheme.green,
                          size: 42,
                        ),
                      ),
                    ],
                  ),
                  const RichAttributionWidget(
                    attributions: [TextSourceAttribution('© OpenStreetMap contributors')],
                  ),
                ],
              ),
              Positioned(
                top: 16,
                left: 16,
                child: Container(
                  decoration: BoxDecoration(
                    color: AllwaysTheme.green,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: const [BoxShadow(color: Color(0x24000000), blurRadius: 12, offset: Offset(0, 4))],
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  child: Text(
                    _hasCurrentLocation ? 'Pickup point' : 'Pickup area preview',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              Positioned(
                right: 12,
                bottom: 14,
                child: Column(
                  children: [
                    FloatingActionButton.small(
                      heroTag: 'travel-zoom-in',
                      onPressed: () => _mapController.move(_center, 16),
                      child: const Icon(Icons.add),
                    ),
                    const SizedBox(height: 8),
                    FloatingActionButton.small(
                      heroTag: 'travel-use-location',
                      onPressed: _locating ? null : _useCurrentLocation,
                      child: _locating
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.my_location),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          flex: 6,
          child: ListView(
            key: const PageStorageKey<String>('customer-travel-panel'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            children: [
              Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFE7F8ED),
                    child: Icon(Icons.my_location, color: AllwaysTheme.green),
                  ),
                  title: const Text('Pickup point', style: TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: Text(_hasCurrentLocation ? 'Current device location selected' : 'Use the location button to find your current position'),
                  trailing: IconButton(
                    tooltip: 'Use current location',
                    onPressed: _locating ? null : _useCurrentLocation,
                    icon: const Icon(Icons.my_location, color: AllwaysTheme.green),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _destinationController,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _continueToBooking(),
                decoration: const InputDecoration(
                  hintText: 'Where are you going?',
                  prefixIcon: Icon(Icons.search_rounded),
                  border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(28))),
                  filled: true,
                ),
              ),
              const SizedBox(height: 14),
              const Text('Travel with ALLways', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'bike', icon: Icon(Icons.two_wheeler), label: Text('Bike')),
                  ButtonSegment(value: 'auto', icon: Icon(Icons.electric_rickshaw), label: Text('Auto')),
                  ButtonSegment(value: 'car', icon: Icon(Icons.directions_car_outlined), label: Text('Car')),
                ],
                selected: {_vehicle},
                onSelectionChanged: (values) => setState(() => _vehicle = values.first),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _continueToBooking,
                icon: const Icon(Icons.arrow_forward_rounded),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Continue to booking'),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: AllwaysTheme.green,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ServiceLanding extends StatelessWidget {
  const _ServiceLanding({required this.icon, required this.title, required this.description, required this.label});
  final IconData icon;
  final String title;
  final String description;
  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircleAvatar(radius: 30, backgroundColor: const Color(0xFFE7F8ED), child: Icon(icon, size: 32, color: AllwaysTheme.green)),
            const SizedBox(height: 14),
            Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            Text(description, textAlign: TextAlign.center),
            const SizedBox(height: 14),
            Text(label, textAlign: TextAlign.center, style: const TextStyle(color: AllwaysTheme.green, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    ),
  );
}

class OrdersTab extends StatelessWidget {
  const OrdersTab({required this.user, super.key});
  final User? user;

  @override
  Widget build(BuildContext context) {
    if (user == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Sign in to view your orders.'),
          const SizedBox(height: 10),
          FilledButton(onPressed: () => context.push('/login'), child: const Text('Sign in')),
        ]),
      );
    }
    return OrdersList(customerId: user!.uid);
  }
}
