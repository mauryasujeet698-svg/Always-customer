/// Phone-based Firebase accounts expose their verified phone in User.phoneNumber.
/// Email/Google users without a linked phone must complete phone verification first.
bool hasVerifiedPhoneForCheckout(String? phoneNumber) {
  return phoneNumber != null && phoneNumber.trim().isNotEmpty;
}
