# ALLways Customer — Flutter migration

This branch starts the Android-first Flutter rewrite. The old HTML/CSS/JavaScript files are intentionally retained until equivalent native features pass parity and regression testing.

## Android identity and Firebase

- Android application ID is `com.allways.app`, matching the already-registered Android client in the ALLways Firebase project's existing `google-services.json`.
- The app uses project `allways-web` and Firestore collections already used by the existing customer interface, including `products`, `orders`, `announcements`, `customers`, `autoRideRequests` and `fcmTokens`.
- Do not remove or regenerate the Firebase config, OAuth setup, package ID, release signing key, Apps Script order integration or backend fields during migration.
- Phone OTP is required before order placement. Existing Google/email sign-in remains available, but users must link/verify a phone before checkout can submit an order.
- Online payment is deliberately disabled and labelled "Currently unavailable"; only cash on delivery is selectable.

## Verification

Run with a recent Flutter stable SDK (Dart 3.12+):

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

The first native migration pass covers the app shell, cached catalog images, shop/cart, phone verification, checkout gate, order history and notification token registration. Food ordering, saved-address management, ride request details, parcel flow, favorites, reorder, cancellation, ratings, full support flows and any existing CMS workflows must be migrated and regression-tested before the legacy web files are removed.

## Caching and state

- Catalog fetching is owned by a Riverpod `FutureProvider` instead of starting a new query on every widget rebuild.
- The customer shell uses `IndexedStack` and `PageStorageKey` to preserve tab and scroll state.
- Product images use `CachedNetworkImage` for disk/memory caching with stable layout placeholders.
- Maps are not re-created from scroll callbacks; a native ride/map screen still needs to be migrated and its tile cache tested separately.

## Rollout rule

Do not merge this branch or remove website files until customer feature parity, Firebase rules, Android release builds, auth/linking, notifications and real-device tests pass.
