import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../data/phone_auth_repository.dart';
import 'auth_providers.dart';

/// Google-only account entry for the current launch phase.
/// Phone OTP and email/password controls are intentionally not shown.
class PhoneLoginScreen extends ConsumerStatefulWidget {
  const PhoneLoginScreen({super.key});

  @override
  ConsumerState<PhoneLoginScreen> createState() => _PhoneLoginScreenState();
}

class _PhoneLoginScreenState extends ConsumerState<PhoneLoginScreen> {
  bool _busy = false;
  String? _error;

  PhoneAuthRepository get _auth => ref.read(authRepositoryProvider);

  Future<void> _signInGoogle() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _auth.signInWithGoogle();
      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/');
      }
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = switch (error.code) {
          'google-sign-in-not-supported' => 'Google Sign-In is not supported on this device.',
          'google-id-token-missing' => 'Google sign-in needs configuration. Please try again later.',
          'network-request-failed' => 'Check your internet connection and try again.',
          'account-exists-with-different-credential' => 'An account already exists with a different sign-in method.',
          _ => error.message ?? 'Google sign-in failed. Please try again.',
        };
      });
    } catch (error) {
      debugPrint('ALLways Google Sign-In failed: $error');
      if (!mounted) return;
      final details = error.toString();
      final oauthMismatch = details.contains('ApiException: 10') ||
          details.contains('DEVELOPER_ERROR') ||
          details.contains('clientConfigurationError');
      setState(() {
        _error = oauthMismatch
            ? 'Google Sign-In configuration error. Add the SHA-1 and SHA-256 fingerprints for com.allways.app in Firebase Console, ensure Google is enabled, then download the updated google-services.json.'
            : 'Google sign-in failed: $details';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ALLways Account')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(26),
                  side: const BorderSide(color: AllwaysTheme.line),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const CircleAvatar(
                        radius: 34,
                        backgroundColor: Color(0xFFFFE1EC),
                        child: Icon(Icons.person_outline_rounded, size: 34, color: AllwaysTheme.purple),
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        'Welcome to ALLways',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Sign in securely with your Google account to continue.',
                        textAlign: TextAlign.center,
                        style: TextStyle(height: 1.45),
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: _busy ? null : _signInGoogle,
                        icon: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.login_rounded),
                        label: Text(_busy ? 'Signing in…' : 'Continue with Google'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                          backgroundColor: AllwaysTheme.purple,
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ],
                      const SizedBox(height: 14),
                      const Text(
                        'You can browse ALLways as a guest. Sign in when you are ready to continue.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey, fontSize: 12, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
