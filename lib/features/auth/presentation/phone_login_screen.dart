import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../data/phone_auth_repository.dart';
import 'auth_providers.dart';

class PhoneLoginScreen extends ConsumerStatefulWidget {
  const PhoneLoginScreen({super.key});

  @override
  ConsumerState<PhoneLoginScreen> createState() => _PhoneLoginScreenState();
}

class _PhoneLoginScreenState extends ConsumerState<PhoneLoginScreen> {
  final _phone = TextEditingController();
  final _otp = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();

  String? _verificationId;
  String? _message;
  String? _error;
  bool _busy = false;
  bool _showOtherSignIn = false;

  @override
  void dispose() {
    _phone.dispose();
    _otp.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  PhoneAuthRepository get _auth => ref.read(authRepositoryProvider);

  Future<void> _sendCode() async {
    final digits = _phone.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 10) {
      setState(() => _error = 'Enter a valid 10-digit Indian mobile number.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _message = 'Sending verification code…';
    });
    try {
      await _auth.sendVerificationCode(
        phoneNumber: '+91$digits',
        onCodeSent: (id) {
          if (!mounted) return;
          setState(() {
            _verificationId = id;
            _busy = false;
            _message = 'OTP sent. Enter the code received on your phone.';
          });
        },
        onError: (error) {
          if (!mounted) return;
          setState(() {
            _busy = false;
            _error = _friendlyError(error);
            _message = null;
          });
        },
        onAutoVerified: (credential) async {
          try {
            await _auth.completeAutoVerification(credential);
            if (mounted) _finishLogin();
          } on FirebaseAuthException catch (error) {
            if (mounted) setState(() => _error = _friendlyError(error));
          } catch (error) {
            if (mounted) setState(() => _error = error.toString());
          } finally {
            if (mounted) setState(() => _busy = false);
          }
        },
      );
    } on FirebaseAuthException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _friendlyError(error);
          _message = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.toString();
          _message = null;
        });
      }
    }
  }

  Future<void> _verifyCode() async {
    final id = _verificationId;
    if (id == null || _otp.text.trim().length < 4) {
      setState(() => _error = 'Enter the SMS verification code.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _message = 'Verifying your number…';
    });
    try {
      await _auth.verifySmsCode(
        verificationId: id,
        smsCode: _otp.text.trim(),
      );
      if (mounted) _finishLogin();
    } on FirebaseAuthException catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = null;
        });
      }
    }
  }

  Future<void> _signInWithEmail({required bool create}) async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.length < 6) {
      setState(() => _error = 'Enter a valid email and a password of at least 6 characters.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      if (create) {
        await _auth.createEmailAccount(email: email, password: password);
      } else {
        await _auth.signInWithEmail(email: email, password: password);
      }
      if (mounted) {
        setState(() => _message =
            'Signed in. Verify your mobile number before placing an order.');
      }
    } on FirebaseAuthException catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signInGoogle() async {
    setState(() { _busy = true; _error = null; });
    try {
      await _auth.signInWithGoogle();
      if (mounted) {
        setState(() => _message =
            'Signed in. Verify your mobile number before placing an order.');
      }
    } on FirebaseAuthException catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetPassword() async {
    if (_email.text.trim().isEmpty) {
      setState(() => _error = 'Enter your email first to reset your password.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await _auth.sendPasswordReset(_email.text.trim());
      if (mounted) setState(() => _message = 'Password reset email sent.');
    } on FirebaseAuthException catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendlyError(FirebaseAuthException error) {
    switch (error.code) {
      case 'invalid-phone-number':
        return 'That mobile number is not valid. Check the number and try again.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait before trying again.';
      case 'invalid-verification-code':
        return 'That OTP is incorrect. Check the message and try again.';
      case 'session-expired':
        return 'This OTP has expired. Request a new code.';
      case 'credential-already-in-use':
        return 'This phone number is already linked to another account. Sign in with that account instead.';
      case 'network-request-failed':
        return 'Network connection failed. Check your internet and retry.';
      default:
        return error.message ?? error.code;
    }
  }

  void _finishLogin() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Mobile number verified.')),
    );
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ALLways Account')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const CircleAvatar(
                        radius: 30,
                        backgroundColor: Color(0xFFE7F8ED),
                        child: Icon(Icons.phone_android, size: 30, color: AllwaysTheme.green),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Sign in to ALLways',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Verify your mobile number before placing an order.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _phone,
                        keyboardType: TextInputType.phone,
                        maxLength: 10,
                        decoration: const InputDecoration(
                          labelText: 'Mobile number',
                          prefixText: '+91 ',
                          prefixIcon: Icon(Icons.call_outlined),
                          counterText: '',
                        ),
                      ),
                      if (_verificationId != null) ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: _otp,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          decoration: const InputDecoration(
                            labelText: 'SMS verification code',
                            prefixIcon: Icon(Icons.sms_outlined),
                            counterText: '',
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      FilledButton(
                        onPressed: _busy ? null : (_verificationId == null ? _sendCode : _verifyCode),
                        child: _busy
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : Text(_verificationId == null ? 'Send OTP' : 'Verify & continue'),
                      ),
                      if (_verificationId != null)
                        TextButton(
                          onPressed: _busy ? null : () {
                            setState(() { _verificationId = null; _otp.clear(); _message = null; });
                          },
                          child: const Text('Use a different number'),
                        ),
                      if (_message != null) ...[
                        const SizedBox(height: 10),
                        Text(_message!, textAlign: TextAlign.center, style: const TextStyle(color: AllwaysTheme.green)),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 10),
                        Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)),
                      ],
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _signInGoogle,
                        icon: const Icon(Icons.account_circle_outlined),
                        label: const Text('Continue with Google'),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => setState(() => _showOtherSignIn = !_showOtherSignIn),
                        child: Text(_showOtherSignIn ? 'Hide email options' : 'Sign in or create account with email'),
                      ),
                      if (_showOtherSignIn) ...[
                        TextField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.email_outlined)),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _password,
                          obscureText: true,
                          decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_outline)),
                        ),
                        const SizedBox(height: 12),
                        Row(children: [
                          Expanded(child: FilledButton.tonal(onPressed: _busy ? null : () => _signInWithEmail(create: false), child: const Text('Sign in'))),
                          const SizedBox(width: 10),
                          Expanded(child: OutlinedButton(onPressed: _busy ? null : () => _signInWithEmail(create: true), child: const Text('Create account'))),
                        ]),
                        TextButton(onPressed: _busy ? null : _resetPassword, child: const Text('Forgot password?')),
                      ],
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
