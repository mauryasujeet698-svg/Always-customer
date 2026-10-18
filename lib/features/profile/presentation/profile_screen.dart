import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return Scaffold(
      appBar: AppBar(title: const Text('Account & settings')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person_outline)),
              title: Text(user?.displayName ?? user?.phoneNumber ?? user?.email ?? 'Guest customer'),
              subtitle: Text(user == null
                  ? 'Browse as guest. Sign in before placing an order.'
                  : (user.phoneNumber?.isNotEmpty == true
                      ? 'Mobile number verified'
                      : 'Phone verification is required before ordering')),
              trailing: user?.phoneNumber?.isNotEmpty == true
                  ? const Icon(Icons.verified, color: AllwaysTheme.green)
                  : const Icon(Icons.chevron_right),
              onTap: () {
                if (user?.phoneNumber?.isNotEmpty != true) context.push('/login');
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
          Card(child: const ListTile(
            leading: Icon(Icons.payment_outlined),
            title: Text('Payment methods'),
            subtitle: Text('Online payments are currently unavailable'),
            trailing: Icon(Icons.lock_outline, color: Colors.grey),
            enabled: false,
          )),
          Card(child: const ListTile(
            leading: Icon(Icons.location_on_outlined),
            title: Text('Saved addresses'),
            subtitle: Text('Manage delivery addresses during checkout'),
          )),
          Card(child: const ListTile(
            leading: Icon(Icons.support_agent_outlined),
            title: Text('Customer support'),
            subtitle: Text('Support options will be available here'),
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
