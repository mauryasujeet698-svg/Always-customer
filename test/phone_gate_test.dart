import 'package:flutter_test/flutter_test.dart';
import 'package:allways_customer/features/auth/domain/phone_gate.dart';

void main() {
  group('hasVerifiedPhoneForCheckout', () {
    test('blocks a guest', () {
      expect(hasVerifiedPhoneForCheckout(null), isFalse);
    });

    test('blocks a signed-in account without a phone number', () {
      expect(hasVerifiedPhoneForCheckout(''), isFalse);
      expect(hasVerifiedPhoneForCheckout('   '), isFalse);
    });

    test('allows an account with a verified Firebase phone number', () {
      expect(hasVerifiedPhoneForCheckout('+919876543210'), isTrue);
    });
  });
}
