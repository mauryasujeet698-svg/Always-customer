# ALLways in-app APK updates

## How updates work

The updater reads the app's public release manifest from Firestore, listens for manifest changes while the app is running, downloads the exact APK over HTTPS, verifies its SHA-256 digest, and asks Android to install it. If no valid Firestore manifest is available, the app falls back to the GitHub release tagged `allways-latest`.

The release workflow is intentionally manual. Bump `version:` in `pubspec.yaml`, run the QA checks, and select `publish_update: true` only when you are ready to publish. The APK must remain at or below 25 MiB.

## Required repository Actions secrets

Set these secrets in each of the Customer, Driver Partner and Delivery Partner repositories:

- `ANDROID_KEYSTORE_BASE64` — base64 encoding of the persistent release keystore.
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`
- `FIREBASE_SERVICE_ACCOUNT_JSON` — a service-account JSON for the ALLways Firebase project, permitted to write the three public update manifest documents.

Generate a keystore once and securely back it up. Use the same keystore and alias consistently for subsequent releases of these packages. Never commit a keystore, key properties file, password or service-account JSON into a repository.

Example on a machine with Java's `keytool` installed:

```bash
keytool -genkeypair -v -keystore allways-release.jks -alias allways-release -keyalg RSA -keysize 2048 -validity 10000
```

On Windows PowerShell, convert that file into a single-line secret value with:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("allways-release.jks")) | Set-Clipboard
```

Use the exact passwords and alias chosen when generating the keystore. Do not regenerate the keystore for routine releases.

## Manifest documents and release assets

- Customer: `settings/appUpdate`, asset `allways-latest.apk`
- Driver Partner: `settings/driverPartnerAppUpdate`, asset `allways-driver-partner-latest.apk`
- Delivery Partner: `settings/deliveryPartnerAppUpdate`, asset `allways-delivery-partner-latest.apk`

The publish workflow updates the GitHub release and then writes the version, HTTPS URL, digest and notes to Firestore. The app can show the update banner immediately after this document changes while its listener is connected.

## Android installation limitation

An in-app updater cannot guarantee a silent or instantaneous install. Android may require the user to permit installs from ALLways and confirm the installation. The user must reopen the app to see an update if it was closed or unable to receive the live Firestore change.

Android also rejects an APK whose signing certificate differs from the installed app's certificate. QA APKs produced before a persistent release key is configured may not be upgradeable to the first stable signed release; verify signer continuity on test devices before distribution. If certificates differ, a one-time uninstall/reinstall of the test build may be required.
