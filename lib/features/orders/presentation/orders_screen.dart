import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../cart/presentation/cart_provider.dart';
import '../../catalog/domain/product.dart';
import '../../catalog/presentation/catalog_providers.dart';

class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('My Orders')),
        body: Center(
          child: FilledButton(
            onPressed: () => context.push('/login'),
            child: const Text('Sign in to view orders'),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('My Orders')),
      body: OrdersList(customerId: user.uid),
    );
  }
}

class OrdersList extends ConsumerWidget {
  const OrdersList({required this.customerId, super.key});

  final String customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('orders')
          .where('customerId', isEqualTo: customerId)
          .limit(50)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Could not load your orders. Please try again later.'),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snapshot.data!.docs.toList()
          ..sort((a, b) {
            final aa = a.data()['createdAt'];
            final bb = b.data()['createdAt'];
            final at = aa is num ? aa.toInt() : 0;
            final bt = bb is num ? bb.toInt() : 0;
            return bt.compareTo(at);
          });
        if (docs.isEmpty) {
          return const Center(child: Text('No orders yet.'));
        }

        return ListView.separated(
          key: const PageStorageKey<String>('customer-orders-list'),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final document = docs[index];
            final order = document.data();
            final items = order['items'] is List ? order['items'] as List : const [];
            final itemText = items.map((item) {
              if (item is Map) {
                return '${item['name'] ?? 'Item'} × ${item['qty'] ?? 1}';
              }
              return 'Item';
            }).join(', ');
            final orderId = (order['id'] ?? document.id).toString();
            final status = (order['status'] ?? 'Received').toString();
            final statusNormalized = status.trim().toLowerCase();
            final total = (order['total'] as num?)?.toDouble() ?? 0;
            final canCancel = status == 'New Order' || status == 'Confirmed';
            final isDelivered = statusNormalized == 'delivered' || statusNormalized == 'completed';
            final rating = (order['rating'] as num?)?.toInt();

            return Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(child: Text('#$orderId', style: const TextStyle(fontWeight: FontWeight.w900))),
                      Chip(label: Text(status, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ]),
                    const SizedBox(height: 6),
                    Text(itemText, maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 8),
                    Text('Total ₹${total.toStringAsFixed(0)}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                    if ((order['statusNote'] ?? '').toString().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(order['statusNote'].toString(), style: Theme.of(context).textTheme.bodySmall),
                      ),
                    if ((order['cancellationReason'] ?? '').toString().trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(
                          'Cancellation reason: ${order['cancellationReason']}',
                          style: const TextStyle(color: Colors.red, fontSize: 12),
                        ),
                      ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => context.push('/support?orderId=${Uri.encodeComponent(document.id)}'),
                          icon: const Icon(Icons.support_agent_outlined),
                          label: const Text('Help'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _reorder(context, ref, items),
                          icon: const Icon(Icons.replay_outlined),
                          label: const Text('Reorder'),
                        ),
                        if (canCancel)
                          OutlinedButton.icon(
                            onPressed: () => _cancelOrder(context, document.reference),
                            icon: const Icon(Icons.cancel_outlined),
                            label: const Text('Cancel order'),
                          ),
                        if (isDelivered && rating == null)
                          OutlinedButton.icon(
                            onPressed: () => _rateOrder(context, document.reference),
                            icon: const Icon(Icons.star_outline),
                            label: const Text('Rate order'),
                          ),
                        if (rating != null)
                          Chip(
                            avatar: const Icon(Icons.star, size: 16, color: Colors.amber),
                            label: Text('Rated $rating/5'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _reorder(
    BuildContext context,
    WidgetRef ref,
    List<dynamic> items,
  ) async {
    final catalog = ref.read(productsProvider).asData?.value;
    if (catalog == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Load the shop catalog before reordering.')),
      );
      return;
    }

    final cartController = ref.read(cartProvider.notifier);
    final currentCart = ref.read(cartProvider);
    var added = 0;
    final skipped = <String>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final id = (item['id'] ?? '').toString();
      final quantity = (item['qty'] as num?)?.toInt() ?? 1;
      Product? product;
      for (final candidate in catalog) {
        if (candidate.id == id) {
          product = candidate;
          break;
        }
      }
      if (product == null || !product.available || product.stock < 1) {
        skipped.add((item['name'] ?? id).toString());
        continue;
      }
      final maximum = product.stock.clamp(1, product.maxQty).toInt();
      cartController.setQuantity(
        id,
        (currentCart[id] ?? 0) + quantity,
        maximum: maximum,
      );
      added += 1;
    }

    if (context.mounted) {
      final message = added == 0
          ? 'No items from this order are currently available to reorder.'
          : skipped.isEmpty
              ? 'Available items were added to your cart.'
              : 'Available items added. Unavailable: ${skipped.take(3).join(', ')}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      if (added > 0) context.go('/');
    }
  }

  Future<void> _cancelOrder(
    BuildContext context,
    DocumentReference<Map<String, dynamic>> reference,
  ) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel order?'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Cancellation reason',
            hintText: 'Please tell us why you are cancelling',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Keep order')),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isEmpty) return;
              Navigator.pop(dialogContext, controller.text.trim());
            },
            child: const Text('Confirm cancellation'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reason == null || reason.trim().isEmpty) return;

    try {
      await reference.update({
        'status': 'Cancelled',
        'statusNote': 'Cancelled by customer',
        'cancellationReason': reason.trim(),
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
    } on FirebaseException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not cancel order (${error.code}).')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not cancel the order. Please retry.')),
        );
      }
    }
  }

  Future<void> _rateOrder(
    BuildContext context,
    DocumentReference<Map<String, dynamic>> reference,
  ) async {
    var selected = 5;
    final rating = await showDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Rate your order'),
          content: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(5, (index) {
              final value = index + 1;
              return IconButton(
                tooltip: '$value star${value == 1 ? '' : 's'}',
                onPressed: () => setDialogState(() => selected = value),
                icon: Icon(
                  value <= selected ? Icons.star : Icons.star_border,
                  color: Colors.amber,
                  size: 30,
                ),
              );
            }),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, selected), child: const Text('Submit rating')),
          ],
        ),
      ),
    );
    if (rating == null) return;
    try {
      await reference.update({
        'rating': rating,
        'ratedAt': DateTime.now().millisecondsSinceEpoch,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
    } on FirebaseException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save rating (${error.code}).')),
        );
      }
    }
  }
}
