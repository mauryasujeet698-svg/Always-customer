import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

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

class OrdersList extends StatelessWidget {
  const OrdersList({required this.customerId, super.key});

  final String customerId;

  @override
  Widget build(BuildContext context) {
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
            final order = docs[index].data();
            final items = order['items'] is List ? order['items'] as List : const [];
            final itemText = items.map((item) {
              if (item is Map) {
                return '${item['name'] ?? 'Item'} × ${item['qty'] ?? 1}';
              }
              return 'Item';
            }).join(', ');
            final orderId = (order['id'] ?? docs[index].id).toString();
            final status = (order['status'] ?? 'Received').toString();
            final total = (order['total'] as num?)?.toDouble() ?? 0;
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
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
