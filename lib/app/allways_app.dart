import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/theme_mode_provider.dart';
import '../features/auth/presentation/auth_providers.dart';
import '../features/auth/presentation/phone_login_screen.dart';
import '../features/checkout/presentation/checkout_screen.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/notifications/customer_notification_service.dart';
import '../features/orders/presentation/orders_screen.dart';
import '../features/profile/presentation/profile_screen.dart';
import '../features/rides/presentation/ride_request_screen.dart';

final customerNotificationServiceProvider =
    Provider<CustomerNotificationService>((ref) {
  final service = CustomerNotificationService();
  ref.onDispose(service.dispose);
  return service;
});

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
      GoRoute(
        path: '/login',
        builder: (context, state) => const PhoneLoginScreen(),
      ),
      GoRoute(
        path: '/checkout',
        builder: (context, state) => const CheckoutScreen(),
      ),
      GoRoute(
        path: '/orders',
        builder: (context, state) => const OrdersScreen(),
      ),
      GoRoute(path: '/ride', builder: (context, state) => const RideRequestScreen()),
      GoRoute(
        path: '/profile',
        builder: (context, state) => const ProfileScreen(),
      ),
    ],
  );
});

final GlobalKey<ScaffoldMessengerState> customerScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

class AllwaysCustomerApp extends ConsumerStatefulWidget {
  const AllwaysCustomerApp({super.key});

  @override
  ConsumerState<AllwaysCustomerApp> createState() => _AllwaysCustomerAppState();
}

class _AllwaysCustomerAppState extends ConsumerState<AllwaysCustomerApp> {
  StreamSubscription<RemoteMessage>? _foregroundMessages;
  StreamSubscription<RemoteMessage>? _openedMessages;

  @override
  void initState() {
    super.initState();
    _foregroundMessages = FirebaseMessaging.onMessage.listen((message) {
      final title = message.notification?.title ??
          message.data['title']?.toString() ??
          'ALLways';
      final body = message.notification?.body ??
          message.data['body']?.toString() ??
          message.data['message']?.toString() ??
          '';
      customerScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(body.isEmpty ? title : '$title: $body')),
      );
    });
    _openedMessages = FirebaseMessaging.onMessageOpenedApp.listen((message) {
      ref.read(appRouterProvider).go('/orders');
    });
    FirebaseMessaging.instance.getInitialMessage().then((message) {
      if (message != null && mounted) {
        ref.read(appRouterProvider).go('/orders');
      }
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _foregroundMessages?.cancel();
    _openedMessages?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authStateProvider, (previous, next) {
      final user = next.valueOrNull;
      if (user != null) {
        unawaited(
          ref.read(customerNotificationServiceProvider).registerForUser(user),
        );
      }
    });

    return MaterialApp.router(
      title: 'ALLways',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: customerScaffoldMessengerKey,
      theme: AllwaysTheme.light,
      darkTheme: AllwaysTheme.dark,
      themeMode: ref.watch(themeModeProvider),
      routerConfig: ref.watch(appRouterProvider),
    );
  }
}
