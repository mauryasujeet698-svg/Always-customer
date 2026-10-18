import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

class PhoneAuthRepository {
  PhoneAuthRepository(this._auth);

  final FirebaseAuth _auth;

  Future<void> sendVerificationCode({
    required String phoneNumber,
    required void Function(String verificationId) onCodeSent,
    required void Function(FirebaseAuthException error) onError,
    required Future<void> Function(PhoneAuthCredential credential) onAutoVerified,
  }) async {
    await _auth.verifyPhoneNumber(
      phoneNumber: phoneNumber,
      timeout: const Duration(seconds: 60),
      verificationCompleted: (credential) {
        unawaited(onAutoVerified(credential));
      },
      verificationFailed: onError,
      codeSent: (verificationId, _) => onCodeSent(verificationId),
      codeAutoRetrievalTimeout: onCodeSent,
    );
  }

  Future<UserCredential> verifySmsCode({
    required String verificationId,
    required String smsCode,
  }) async {
    final credential = PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode: smsCode,
    );
    return _completePhoneCredential(credential);
  }

  Future<UserCredential> completeAutoVerification(
    PhoneAuthCredential credential,
  ) => _completePhoneCredential(credential);

  Future<UserCredential> _completePhoneCredential(
    PhoneAuthCredential credential,
  ) async {
    final current = _auth.currentUser;
    // Link the verified phone to an existing Google/email account where possible
    // so existing order ownership and preferences retain the same Firebase UID.
    final UserCredential result;
    if (current != null &&
        (current.phoneNumber == null || current.phoneNumber!.isEmpty)) {
      result = await current.linkWithCredential(credential);
    } else {
      result = await _auth.signInWithCredential(credential);
    }

    // Refresh the Firebase ID token so the phone_number claim is available
    // to server-side Firestore Rules immediately after OTP verification.
    await result.user?.getIdToken(true);
    return result;
  }

  Future<UserCredential> signInWithEmail({
    required String email,
    required String password,
  }) {
    return _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<UserCredential> createEmailAccount({
    required String email,
    required String password,
  }) {
    return _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<void> sendPasswordReset(String email) {
    return _auth.sendPasswordResetEmail(email: email.trim());
  }

  Future<UserCredential> signInWithGoogle() async {
    if (!GoogleSignIn.instance.supportsAuthenticate()) {
      throw FirebaseAuthException(
        code: 'google-sign-in-not-supported',
        message: 'Google Sign-In is not supported on this device.',
      );
    }
    final googleUser = await GoogleSignIn.instance.authenticate();
    final googleAuth = googleUser.authentication;
    final idToken = googleAuth.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw FirebaseAuthException(
        code: 'google-id-token-missing',
        message: 'Google Sign-In did not return an ID token.',
      );
    }
    return _auth.signInWithCredential(
      GoogleAuthProvider.credential(idToken: idToken),
    );
  }

  Future<void> signOut() => _auth.signOut();
}
