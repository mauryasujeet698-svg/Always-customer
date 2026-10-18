import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../data/saved_address_repository.dart';
import '../domain/saved_address.dart';
import 'address_providers.dart';

class SavedAddressesScreen extends ConsumerWidget {
  const SavedAddressesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Saved addresses')),
        body: Center(
          child: FilledButton(
            onPressed: () => context.push('/login'),
            child: const Text('Sign in to manage addresses'),
          ),
        ),
      );
    }

    final addresses = ref.watch(savedAddressesProvider(user.uid));
    return Scaffold(
      appBar: AppBar(title: const Text('Saved addresses')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddressDialog(context, ref, user),
        icon: const Icon(Icons.add_location_alt_outlined),
        label: const Text('Add address'),
      ),
      body: addresses.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const Center(child: Text('Could not load saved addresses.')),
        data: (items) {
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Text(
                  'No saved addresses yet. Add one here or save an address during checkout.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            key: const PageStorageKey<String>('customer-saved-addresses'),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 100),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final address = items[index];
              return Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFE7F8ED),
                    child: Icon(Icons.location_on_outlined, color: AllwaysTheme.green),
                  ),
                  title: Text(address.name.isEmpty ? 'Saved address' : address.name),
                  subtitle: Text(
                    '${address.address}${address.phone.isEmpty ? '' : '\n${address.phone}'}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isThreeLine: true,
                  trailing: IconButton(
                    tooltip: 'Delete address',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _deleteAddress(context, ref, user.uid, address),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  static Future<void> _showAddressDialog(
    BuildContext context,
    WidgetRef ref,
    User user,
  ) async {
    final name = TextEditingController(text: user.displayName ?? '');
    final phone = TextEditingController(text: user.phoneNumber ?? '');
    final address = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add saved address'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(
                controller: name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (value) => (value ?? '').trim().isEmpty ? 'Enter a name.' : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Contact phone'),
                validator: (value) => (value ?? '').replaceAll(RegExp(r'\D'), '').length < 10
                    ? 'Enter a contact number.'
                    : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: address,
                minLines: 2,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Full address'),
                validator: (value) => (value ?? '').trim().length < 8 ? 'Enter a fuller address.' : null,
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() == true) {
                Navigator.pop(dialogContext, true);
              }
            },
            child: const Text('Save address'),
          ),
        ],
      ),
    );

    try {
      if (save == true) {
        await ref.read(savedAddressRepositoryProvider).upsert(
          uid: user.uid,
          name: name.text.trim(),
          phone: phone.text.trim(),
          address: address.text.trim(),
        );
        ref.invalidate(savedAddressesProvider(user.uid));
      }
    } finally {
      name.dispose();
      phone.dispose();
      address.dispose();
    }
  }

  static Future<void> _deleteAddress(
    BuildContext context,
    WidgetRef ref,
    String uid,
    SavedAddress address,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete saved address?'),
        content: Text('Remove "${address.address}" from saved addresses?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirm != true) return;
    await ref.read(savedAddressRepositoryProvider).delete(uid, address.id);
    ref.invalidate(savedAddressesProvider(uid));
  }
}
