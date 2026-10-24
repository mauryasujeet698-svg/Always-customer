# ALLways Customer App

This branch is the Android-first native customer application built with **Flutter and Dart**.

## Technology structure

- **Customer app UI and app logic:** Flutter + Dart in `lib/`.
- **Authentication, database, messaging and storage:** the existing Firebase project and its configured Flutter SDKs.
- **Backend functions:** JavaScript on Node.js in `functions/index.js`. This is backend infrastructure, not a second customer frontend; keep it.
- **Android build configuration:** the native Android files required by Flutter and the existing Firebase client configuration.

## Legacy frontend cleanup

The unused legacy customer frontend files (`app.js`, `index.html`, `styles.css`) and old frontend/admin files removed in this migration are not part of the Flutter app. Do not restore a parallel HTML/CSS/JavaScript customer UI on this branch. The separate backend in `functions/` must remain.

## Firebase safety

- Keep `android/app/google-services.json` and the existing Firebase project configuration unchanged.
- Keep the Android application ID `com.allways.app`.
- Keep the Apps Script order-sync integration and existing backend fields unless a reviewed change specifically requires otherwise.
- Do not rotate, replace, or delete Firebase configuration as part of language cleanup.

## Verification

With the Flutter stable SDK matching the Dart constraint in `pubspec.yaml`, run:

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

A successful build confirms compilation only; each customer flow and Firebase sign-in/configuration must also be tested on a real Android device before release.
