import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../allways_design.dart';

class NotificationsSettingsScreen extends StatefulWidget {
  const NotificationsSettingsScreen({super.key});

  @override
  State<NotificationsSettingsScreen> createState() =>
      _NotificationsSettingsScreenState();
}

class _NotificationsSettingsScreenState
    extends State<NotificationsSettingsScreen> {
  bool _allwaysNotifications = true;
  bool _orderUpdates = true;
  bool _deliveryUpdates = true;
  bool _travelUpdates = true;
  bool _offersPromotions = true;
  bool _announcements = true;
  String _selectedTab = 'All';

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _allwaysNotifications = prefs.getBool('notifications_enabled') ?? prefs.getBool('allways_notifications_enabled') ?? true;
      _orderUpdates = prefs.getBool('notification_orderUpdates') ?? true;
      _deliveryUpdates = prefs.getBool('notification_deliveryUpdates') ?? true;
      _travelUpdates = prefs.getBool('notification_travelUpdates') ?? true;
      _offersPromotions = prefs.getBool('notification_offers') ?? false;
      _announcements = prefs.getBool('notification_announcements') ?? false;
    });
  }

  Future<void> _setPreference(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);

    if (key == 'allways_notifications_enabled') {
      await prefs.setBool('notifications_enabled', value);
      if (value) {
        final status = await FirebaseMessaging.instance.requestPermission(
          alert: true, badge: true, sound: true, provisional: false,
        );
        if (status.authorizationStatus == AuthorizationStatus.denied) {
          await prefs.setBool('notifications_enabled', false);
          await prefs.setBool('allways_notifications_enabled', false);
          if (mounted) setState(() => _allwaysNotifications = false);
          return;
        }
        await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
          alert: true, badge: true, sound: true,
        );
        await FirebaseMessaging.instance.subscribeToTopic('all_users');
        await FirebaseMessaging.instance.subscribeToTopic('customers');

        final token = await FirebaseMessaging.instance.getToken();
        final user = FirebaseAuth.instance.currentUser;
        if (token != null && token.isNotEmpty && user != null) {
          await FirebaseFirestore.instance.collection('fcmTokens').doc(user.uid).set({
            'uid': user.uid,
            'email': user.email ?? '',
            'token': token,
            'notificationsEnabled': true,
            'notificationPreferences': {
              'orderUpdates': prefs.getBool('notification_orderUpdates') ?? true,
              'deliveryUpdates': prefs.getBool('notification_deliveryUpdates') ?? true,
              'travelUpdates': prefs.getBool('notification_travelUpdates') ?? true,
              'offers': prefs.getBool('notification_offers') ?? true,
              'announcements': prefs.getBool('notification_announcements') ?? true,
            },
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
          await FirebaseFirestore.instance.collection('fcmTokens').doc(user.uid).collection('tokens').doc(token).set({
            'uid': user.uid,
            'token': token,
            'notificationsEnabled': true,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
          await prefs.setString('allways_fcm_token', token);
        }
      } else {
        await FirebaseMessaging.instance.unsubscribeFromTopic('all_users');
        await FirebaseMessaging.instance.unsubscribeFromTopic('customers');
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          final token = await FirebaseMessaging.instance.getToken();
          await FirebaseFirestore.instance.collection('fcmTokens').doc(user.uid).set({
            'uid': user.uid,
            'notificationsEnabled': false,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
          if (token != null && token.isNotEmpty) {
            await FirebaseFirestore.instance.collection('fcmTokens').doc(user.uid).collection('tokens').doc(token).set({
              'uid': user.uid,
              'token': token,
              'notificationsEnabled': false,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          }
        }
      }
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        final prefsMap = {
          'orderUpdates': prefs.getBool('notification_orderUpdates') ?? true,
          'deliveryUpdates': prefs.getBool('notification_deliveryUpdates') ?? true,
          'travelUpdates': prefs.getBool('notification_travelUpdates') ?? true,
          'offers': prefs.getBool('notification_offers') ?? true,
          'announcements': prefs.getBool('notification_announcements') ?? true,
        };
        await FirebaseFirestore.instance.collection('customers').doc(user.uid).set({
          'notification_preferences': prefsMap,
          'notificationsEnabled': prefs.getBool('notifications_enabled') ?? true,
        }, SetOptions(merge: true));
        await FirebaseFirestore.instance.collection('fcmTokens').doc(user.uid).set({
          'uid': user.uid,
          'notificationPreferences': prefsMap,
          'notificationsEnabled': prefs.getBool('notifications_enabled') ?? true,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (e) {
        debugPrint('ALLways notif pref save: $e');
      }
    }
  }
  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Notifications',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'Stay updated with your ALLways activity',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.close, color: Theme.of(context).colorScheme.onSurfaceVariant),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFFFE7F1), Color(0xFFFFF3F7)],
              ),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: AllwaysColors.border),
            ),
            child: Column(
              children: [
                Container(
                  width: 104,
                  height: 104,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: AllwaysColors.primarySoft,
                  ),
                  child: const Icon(Icons.notifications_active_rounded, size: 58, color: AllwaysColors.primary),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Stay updated at every step!',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 25, height: 1.05, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 8),
                Text(
                  'Get real-time notifications about your order, delivery updates, offers and more.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AllwaysColors.muted, height: 1.35),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _buildToggleCard(
            title: 'ALLways notifications',
            subtitle: 'Central app alerts and updates',
            icon: Icons.notifications_none,
            value: _allwaysNotifications,
            onChanged: (v) {
              setState(() => _allwaysNotifications = v);
              _setPreference('allways_notifications_enabled', v);
            },
          ),
          const SizedBox(height: 16),
          Text(
            'ORDER & DELIVERY',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                _buildTile(
                  'Order updates',
                  'From confirmation to delivery completion',
                  Icons.receipt_long,
                  _orderUpdates,
                  (v) {
                    setState(() => _orderUpdates = v);
                    _setPreference('notification_orderUpdates', v);
                  },
                ),
                Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
                _buildTile(
                  'Delivery updates',
                  'Partner alerts and tracking status',
                  Icons.local_shipping_outlined,
                  _deliveryUpdates,
                  (v) {
                    setState(() => _deliveryUpdates = v);
                    _setPreference('notification_deliveryUpdates', v);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'TRAVEL & OFFERS',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                _buildTile(
                  'Travel & Ride Updates',
                  'Ride & booking updates',
                  Icons.two_wheeler,
                  _travelUpdates,
                  (v) {
                    setState(() => _travelUpdates = v);
                    _setPreference('notification_travelUpdates', v);
                  },
                ),
                Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
                _buildTile(
                  'Offers & Promotions',
                  'Exclusive deals and reward news',
                  Icons.sell_outlined,
                  _offersPromotions,
                  (v) {
                    setState(() => _offersPromotions = v);
                    _setPreference('notification_offers', v);
                  },
                ),
                Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
                _buildTile(
                  'ALLways Announcements',
                  'Important service news and critical alerts',
                  Icons.campaign_outlined,
                  _announcements,
                  (v) {
                    setState(() => _announcements = v);
                    _setPreference('notification_announcements', v);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'NOTIFICATION HISTORY',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: ['All', 'Orders', 'Delivery', 'Travel', 'Offers'].map((tab) {
                final isSelected = _selectedTab == tab;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(tab),
                    selected: isSelected,
                    selectedColor: AllwaysColors.primary,
                    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
                    labelStyle: TextStyle(
                      color: isSelected ? Colors.white : Theme.of(context).colorScheme.onSurface,
                    ),
                    onSelected: (val) => setState(() => _selectedTab = tab),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 16),
          if (user != null)
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('customers')
                  .doc(user.uid)
                  .collection('notifications')
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        'Notifications unavailable. Pull to refresh or check connection.',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        'No notifications yet.',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ),
                  );
                }

                final docs = snapshot.data!.docs.where((d) {
                  if (_selectedTab == 'All') return true;
                  return (d.data()['category'] ?? '')
                          .toString()
                          .toLowerCase() ==
                      _selectedTab.toLowerCase();
                }).toList();

                if (docs.isEmpty) {
                  return Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        'No notifications in this category.',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ),
                  );
                }

                return ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final item = docs[i].data();
                    return Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: Color(0xFFE8D0D5),
                            child: Icon(
                              Icons.notifications_active,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item['title'] ?? 'Notification',
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.onSurface,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  item['body'] ?? '',
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildToggleCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: const Color(0xFFE8D0D5),
            child: Icon(icon, color: Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            activeThumbColor: Theme.of(context).colorScheme.primary,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildTile(
    String title,
    String subtitle,
    IconData icon,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: const Color(0xFFE8D0D5),
        child: Icon(icon, color: Theme.of(context).colorScheme.primary, size: 20),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 14,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 11),
      ),
      trailing: Switch(
        value: value,
        activeThumbColor: Theme.of(context).colorScheme.primary,
        onChanged: onChanged,
      ),
    );
  }
}
