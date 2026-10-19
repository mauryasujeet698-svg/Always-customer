import 'dart:async';
import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/services/order_sync_service.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../addresses/domain/saved_address.dart';
import '../../addresses/presentation/address_providers.dart';
import '../../cart/presentation/cart_provider.dart';
import '../../catalog/domain/product.dart';
import '../../catalog/presentation/catalog_providers.dart';

class CheckoutScreen extends ConsumerStatefulWidget {
  const CheckoutScreen({super.key});

  @override
  ConsumerState<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends ConsumerState<CheckoutScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _note = TextEditingController();
  bool _placingOrder = false;
  String? _error;
  String? _orderRequestId;
  String? _selectedAddressId;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser;
    _name.text = user?.displayName ?? '';
    _phone.text = user?.phoneNumber ?? '';
    _name.addListener(_resetOrderRequestId);
    _address.addListener(_resetOrderRequestId);
    _note.addListener(_resetOrderRequestId);
  }

  void _resetOrderRequestId() {
    if (!_placingOrder) _orderRequestId = null;
  }

  @override
  void dispose() {
    _name.removeListener(_resetOrderRequestId);
    _address.removeListener(_resetOrderRequestId);
    _note.removeListener(_resetOrderRequestId);
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authStateProvider, (previous, next) {
      final user = next.asData?.value;
      if (user != null) {
        if (_phone.text.trim().isEmpty && (user.phoneNumber ?? '').isNotEmpty) _phone.text = user.phoneNumber!;
        if (_name.text.trim().isEmpty && (user.displayName ?? '').isNotEmpty) _name.text = user.displayName!;
        if (_email.text.trim().isEmpty && (user.email ?? '').isNotEmpty) _email.text = user.email!;
      }
    });

    final cart = ref.watch(cartProvider);
    final auth = ref.watch(authStateProvider).asData?.value;
    final productsAsync = ref.watch(productsProvider);
    final savedAddressesAsync = auth == null ? null : ref.watch(savedAddressesProvider(auth.uid));

    return Scaffold(
      appBar: AppBar(title: const Text('Complete your order')),
      body: productsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('Your cart could not be loaded. Return to Shop and retry.')),
        data: (products) {
          final selected = products.where((p) => (cart[p.id] ?? 0) > 0).toList();
          if (selected.isEmpty) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.shopping_cart_outlined, size: 44),
                const SizedBox(height: 10),
                const Text('Your cart is empty.'),
                const SizedBox(height: 10),
                FilledButton(onPressed: () => context.go('/'), child: const Text('Continue shopping')),
              ]),
            );
          }

          final subtotal = selected.fold<double>(
            0,
            (runningTotal, product) => runningTotal + product.price * (cart[product.id] ?? 0),
          );
          final delivery = subtotal >= 499 ? 0.0 : 30.0;
          final total = subtotal + delivery;
          return ListView(
            key: const PageStorageKey<String>('customer-checkout-scroll'),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
            children: [
              if (auth == null)
                Card(
                  color: const Color(0xFFFFE1EC),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Row(children: [
                        Icon(Icons.account_circle_outlined, color: AllwaysTheme.purple),
                        SizedBox(width: 8),
                        Expanded(child: Text('Sign in to place your order', style: TextStyle(fontWeight: FontWeight.w900, color: AllwaysTheme.purple))),
                      ]),
                      const SizedBox(height: 6),
                      const Text('Continue with Google to securely save and track your order.'),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        onPressed: _placingOrder ? null : () => context.push('/login'),
                        icon: const Icon(Icons.login_rounded),
                        label: const Text('Continue with Google'),
                      ),
                    ]),
                  ),
                ),
              const Text('Order summary', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              ...selected.map((product) => _orderRow(product, cart[product.id] ?? 0)),
              const Divider(height: 24),
              _moneyRow('Subtotal', subtotal),
              _moneyRow('Delivery', delivery, valueLabel: delivery == 0 ? 'FREE 🎉' : null),
              const SizedBox(height: 8),
              _moneyRow('Total', total, bold: true),
              const SizedBox(height: 18),
              const Text('Delivery details', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
              const SizedBox(height: 10),
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Your name', prefixIcon: Icon(Icons.person_outline)),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _phone,
                readOnly: phoneVerified,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: 'Verified phone number',
                  prefixIcon: const Icon(Icons.phone_outlined),
                  suffixIcon: phoneVerified ? const Icon(Icons.verified, color: AllwaysTheme.green) : IconButton(
                    tooltip: 'Verify phone',
                    onPressed: () => context.push('/login'),
                    icon: const Icon(Icons.arrow_forward),
                  ),
                  helperText: phoneVerified ? 'Verified by Firebase Authentication' : 'Verify the number before placing your order.',
                ),
              ),
              const SizedBox(height: 10),
              if (savedAddressesAsync != null)
                savedAddressesAsync.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (addresses) {
                    if (addresses.isEmpty) return const SizedBox.shrink();
                    final safeValue = addresses.any((item) => item.id == _selectedAddressId)
                        ? _selectedAddressId
                        : null;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: DropdownButtonFormField<String>(
                        initialValue: safeValue,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Use a saved address',
                          prefixIcon: Icon(Icons.bookmark_border),
                        ),
                        items: addresses.map((item) => DropdownMenuItem<String>(
                          value: item.id,
                          child: Text(item.address, maxLines: 1, overflow: TextOverflow.ellipsis),
                        )).toList(),
                        onChanged: _placingOrder ? null : (id) {
                          SavedAddress? item;
                          for (final address in addresses) {
                            if (address.id == id) {
                              item = address;
                              break;
                            }
                          }
                          if (item == null) return;
                          setState(() => _selectedAddressId = id);
                          _name.text = item.name;
                          if (!phoneVerified && _phone.text.trim().isEmpty) {
                            _phone.text = item.phone;
                          }
                          _address.text = item.address;
                        },
                      ),
                    );
                  },
                ),
              TextField(
                controller: _address,
                minLines: 2,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Delivery address', hintText: 'House number, village/area, landmark', prefixIcon: Icon(Icons.location_on_outlined)),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _note,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Delivery note (optional)', hintText: 'Landmark or delivery instruction'),
              ),
              const SizedBox(height: 18),
              const Text('Payment method', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              Card(
                child: const ListTile(
                  leading: Icon(Icons.payments_outlined, color: AllwaysTheme.green),
                  title: Text('Cash on delivery'),
                  subtitle: Text('Available for this order'),
                  trailing: Icon(Icons.check_circle, color: AllwaysTheme.green),
                ),
              ),
              const Card(
                child: ListTile(
                  leading: Icon(Icons.account_balance_wallet_outlined, color: Colors.grey),
                  title: Text('Online payment'),
                  subtitle: Text('Currently unavailable'),
                  trailing: Icon(Icons.lock_outline, color: Colors.grey),
                  enabled: false,
                ),
              ),
              const SizedBox(height: 12),
              if (_error != null) ...[
                Text(_error!, style: const TextStyle(color: Colors.red)),
                const SizedBox(height: 8),
              ],
              FilledButton(
                onPressed: _placingOrder
                    ? null
                    : () => _placeOrder(
                          user: auth,
                          products: selected,
                          quantities: cart,
                          subtotal: subtotal,
                          delivery: delivery,
                          total: total,
                        ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  child: _placingOrder
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Place order'),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Open-box delivery: check your items before accepting. Payment methods marked unavailable cannot be selected or charged.',
                style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.4),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _orderRow(Product product, int quantity) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(children: [
      Expanded(child: Text('${product.name} × $quantity', maxLines: 2, overflow: TextOverflow.ellipsis)),
      const SizedBox(width: 12),
      Text('₹${(product.price * quantity).toStringAsFixed(0)}', style: const TextStyle(fontWeight: FontWeight.w800)),
    ]),
  );

  Widget _moneyRow(String label, double amount, {String? valueLabel, bool bold = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(children: [
      Expanded(child: Text(label, style: TextStyle(fontWeight: bold ? FontWeight.w900 : FontWeight.normal, fontSize: bold ? 18 : 14))),
      Text(valueLabel ?? '₹${amount.toStringAsFixed(0)}', style: TextStyle(fontWeight: bold ? FontWeight.w900 : FontWeight.w700, fontSize: bold ? 20 : 14)),
    ]),
  );

  Future<void> _placeOrder({
    required User? user,
    required List<Product> products,
    required Map<String, int> quantities,
    required double subtotal,
    required double delivery,
    required double total,
  }) async {
    final currentUser = user;
    if (currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Continue with Google to place your order.')),
      );
      await context.push('/login');
      return;
    }
    // A contact phone can be entered for delivery, but phone OTP is not used
    // as an authentication method in this launch phase.
    final phoneDigits = _phone.text.replaceAll(RegExp(r'\D'), '');
    final cleanPhone = phoneDigits.length > 10
        ? phoneDigits.substring(phoneDigits.length - 10)
        : phoneDigits;
    if (cleanPhone.length != 10) {
      setState(() => _error = 'Enter a 10-digit contact phone number for delivery.');
      return;
    }
    if (_name.text.trim().isEmpty || _address.text.trim().isEmpty) {
      setState(() => _error = 'Please enter your name and delivery address.');
      return;
    }
    if (_placingOrder) return;

    setState(() { _placingOrder = true; _error = null; });
    try {
      final requestId = _orderRequestId ??=
          '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32)}';
      final requestItems = products.map((product) => <String, dynamic>{
        'id': product.id,
        'qty': quantities[product.id] ?? 0,
      }).where((item) => (item['qty'] as int) > 0).toList();

      // Trusted Cloud Function recalculates prices, stock, fees and totals.
      // This client sends only product IDs and quantities.
      final result = await FirebaseFunctions.instanceFor(region: 'asia-south1')
          .httpsCallable('createCustomerOrder')
          .call<Map<String, dynamic>>({
        'requestId': requestId,
        'name': _name.text.trim(),
        'email': currentUser.email ?? '',
        'phone': cleanPhone,
        'address': _address.text.trim(),
        'note': _note.text.trim(),
        'expectedSubtotal': subtotal,
        'items': requestItems,
      });
      final response = result.data;
      final visibleId = (response['orderId'] ?? '').toString();
      final pin = (response['confirmationPin'] ?? '').toString();
      final rawOrder = response['order'];
      if (visibleId.isEmpty || pin.length != 4 || rawOrder is! Map) {
        throw StateError('The server did not return a valid order confirmation. Please check My Orders before retrying.');
      }
      final order = Map<String, dynamic>.from(rawOrder);
      _orderRequestId = null;
      unawaited(syncOrderToGoogleAppsScript(order));

      try {
        await ref.read(savedAddressRepositoryProvider).upsert(
          uid: currentUser.uid,
          name: _name.text.trim(),
          phone: cleanPhone,
          address: _address.text.trim(),
        );
        ref.invalidate(savedAddressesProvider(currentUser.uid));
      } catch (_) {}
      ref.read(cartProvider.notifier).clear();
      if (mounted) {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            icon: const Icon(Icons.check_circle, color: AllwaysTheme.green, size: 42),
            title: const Text('Order received'),
            content: Text('Your ALLways order #$visibleId has been received. Your delivery confirmation PIN is $pin. Share it with your assigned delivery partner only when your order arrives.'),
            actions: [
              FilledButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  context.go('/orders');
                },
                child: const Text('View my orders'),
              ),
            ],
          ),
        );
      }
    } on FirebaseFunctionsException catch (error) {
      if (error.code == 'failed-precondition' || error.code == 'invalid-argument') {
        _orderRequestId = null;
        ref.invalidate(productsProvider);
      }
      if (mounted) {
        setState(() => _error = error.message ?? 'Order could not be placed. Please check your cart and retry.');
      }
    } on FirebaseException catch (error) {
      if (mounted) setState(() => _error = 'Order could not be saved. Please retry. (${error.code})');
    } catch (error) {
      if (mounted) setState(() => _error = error.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _placingOrder = false);
    }
  }
}
