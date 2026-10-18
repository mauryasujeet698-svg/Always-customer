import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/theme_mode_provider.dart';
import '../features/auth/presentation/auth_providers.dart';
import '../features/notifications/customer_notification_service.dart';
import '../features/auth/presentation/phone_login_screen.dart';
import '../features/checkout/presentation/checkout_screen.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/orders/presentation/orders_screen.dart';
import '../features/profile/presentation/profile_screen.dart';

final customerNotificationServiceProvider = Provider<CustomerNotificationService>((ref) {\n  final service = CustomerNotificationService();\n  ref.onDispose(service.dispose);\n  return service;\n});\n\nfinal appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
      GoRoute(path: '/login', builder: (context, state) => const PhoneLoginScreen()),
      GoRoute(path: '/checkout', builder: (context, state) => const CheckoutScreen()),
      GoRoute(path: '/orders', builder: (context, state) => const OrdersScreen()),\n      GoRoute(path: '/profile', builder: (context, state) => const ProfileScreen()),
    ],
  );
});

class AllwaysCustomerApp extends ConsumerWidget {
  const AllwaysCustomerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'ALLways',
      debugShowCheckedModeBanner: false,
      theme: AllwaysTheme.light,
      darkTheme: AllwaysTheme.dark,
      themeMode: ThemeMode.light,
      routerConfig: ref.watch(appRouterProvider),
    );
  }
}
