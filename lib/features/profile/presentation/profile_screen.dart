import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/allways_app.dart';
import '../../../core/theme/app_theme.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _notificationsEnabled = true;
  bool _loadingPreference = true;
  bool _changingPreference = false;

  @override
  void initState() {
    super.initState();
    _loadNotificationPreference();
  }

  Future<void> _loadNotificationPreference() async {
    var enabled = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool('notifications_enabled') ?? true;
    } catch (_) {
      // Keep the default usable when local preferences are unavailable.
    }
    if (!mounted) return;
    setState(() {
      _notificationsEnabled = enabled;
      _loadingPreference = false;
    });
  }

  Future<void> _setNotifications(bool enabled) async {
    if (_changingPreference) return;
    setState(() { _changingPreference = true; });
    try {
      await ref.read(customerNotificationServiceProvider).setEnabled(enabled);
      if (mounted) setState(() => _notificationsEnabled = enabled);
      if (mounted && enabled) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Notification preference saved. Android permission may still be required.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update notifications. Please retry.')),
        );
      }
    } finally {
      if (mounted) setState(() => _changingPreference = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return Scaffold(
      appBar: AppBar(title: const Text('Account & settings')),
      body: ListView(
        key: const PageStorageKey<String>('customer-profile-scroll'),
        padding: const EdgeInsets.all(14),
        children: [
          Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person_outline)),
              title: Text(user?.displayName ?? user?.phoneNumber ?? user?.email ?? 'Guest customer'),
              subtitle: Text(user == null
                  ? 'Browse as a guest, or continue with Google to save your account.'
                  : (user.phoneNumber?.isNotEmpty == true
                      ? 'Mobile number verified'
                      : 'Signed in with Google')),
              trailing: user?.phoneNumber?.isNotEmpty == true
                  ? const Icon(Icons.verified, color: AllwaysTheme.green)
                  : const Icon(Icons.chevron_right),
              onTap: () {
                if (user == null) context.push('/login');
              },
            ),
          ),
          const SizedBox(height: 10),
          Card(child: ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('My orders'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/orders'),
          )),
          Card(child: ListTile(
            leading: const Icon(Icons.favorite_border, color: Colors.red),
            title: const Text('Saved favourites'),
            subtitle: const Text('Browse the shop and tap the heart on a product'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              context.go('/');
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Open Shop and select the heart filter to see saved favourites.')),
              );
            },
          )),
          Card(child: ListTile(
            leading: const Icon(Icons.location_on_outlined),
            title: const Text('Saved addresses'),
            subtitle: const Text('Manage your saved delivery locations'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/addresses'),
          )),
          Card(child: const ListTile(
            leading: Icon(Icons.payment_outlined),
            title: Text('Payment methods'),
            subtitle: Text('Online payments are currently unavailable'),
            trailing: Icon(Icons.lock_outline, color: Colors.grey),
            enabled: false,
          )),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.notifications_active_outlined),
              title: const Text('Notifications'),
              subtitle: Text(_loadingPreference
                  ? 'Loading preference…'
                  : 'Order, ride and service updates'),
              value: _notificationsEnabled,
              onChanged: _loadingPreference || _changingPreference ? null : _setNotifications,
            ),
          ),
          Card(child: ListTile(
            leading: const Icon(Icons.support_agent_outlined),
            title: const Text('Customer support'),
            subtitle: const Text('Get help with an order or your account'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/support'),
          )),
          Card(child: const ListTile(
            leading: Icon(Icons.privacy_tip_outlined),
            title: Text('Privacy & account security'),
            subtitle: Text('Review your account and privacy options'),
          )),
          if (user != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                await FirebaseAuth.instance.signOut();
                if (context.mounted) context.go('/');
              },
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
            ),
          ],
        ],
      ),
    );
  }
}
