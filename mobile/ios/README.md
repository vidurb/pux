# pux iOS

iOS uses Firebase Cloud Messaging (FCM delivers via APNs under the hood), mirroring the Android push flow.

## Setup

1. Create a Firebase iOS app for bundle id `xyz.vidur.pux`.
2. Run `flutterfire configure` in `mobile/` (or copy `GoogleService-Info.plist` to `ios/Runner/`).
3. Set your development team on the Runner and NotificationService targets. Runner has Push Notifications and Keychain Sharing (`$(AppIdentifierPrefix)xyz.vidur.pux.shared`); NotificationService has the same keychain group. Register `xyz.vidur.pux.NotificationService` in the Apple Developer account.
4. Upload your APNs auth key to the Firebase console.

Pushes are alerts that the NotificationService extension decrypts (see "iOS push" in the root README). `scripts/add_notification_service.rb` recreates the extension target in `Runner.xcodeproj`.

## Build

```bash
cd mobile
flutter build ios --dart-define=PUX_SERVER_URL=https://pux.vidur.xyz \
  --dart-define=FIREBASE_IOS_API_KEY=... \
  --dart-define=FIREBASE_IOS_APP_ID=... \
  --dart-define=FIREBASE_MESSAGING_SENDER_ID=... \
  --dart-define=FIREBASE_PROJECT_ID=... \
  --dart-define=FIREBASE_IOS_BUNDLE_ID=xyz.vidur.pux
```

For local dev against a machine on the LAN, point `PUX_SERVER_URL` at your Phoenix server.

## Permissions

`Info.plist` includes camera usage (QR enrollment) and `remote-notification` background mode. Notification permission is requested at runtime.

## TestFlight

The [`testflight`](../../.github/workflows/testflight.yml) workflow archives the app, signs it with an Apple Distribution certificate and App Store provisioning profiles, and uploads it to App Store Connect. It runs on every `v*` release tag, and by hand from the Actions tab (or `gh workflow run testflight.yml`) for builds in between. The build number is the workflow's run number. The version comes from `mobile/pubspec.yaml`.

CI signs manually because signing with only an API key isn't reliable on hosted runners. [`scripts/ci_manual_signing.rb`](scripts/ci_manual_signing.rb) switches the Release configuration of Runner and NotificationService to the installed profiles on the CI checkout only, so local builds keep automatic signing.

### One-time setup

All of this is in the [Apple Developer portal](https://developer.apple.com/account) and [App Store Connect](https://appstoreconnect.apple.com) unless noted.

1. **Team ID.** Find it under Membership details. Store it as a repository variable:
   `gh variable set APPLE_TEAM_ID --body <TEAM_ID>`
2. **App IDs.** Under Certificates, Identifiers & Profiles → Identifiers, register `xyz.vidur.pux` with **Push Notifications** turned on, and `xyz.vidur.pux.NotificationService` with no extra capabilities. Keychain sharing needs no capability.
3. **Push.** Under Keys, create a key with **Apple Push Notifications service (APNs)** and download the `.p8`. In the Firebase console (project `pux-vb`), go to Project settings → Cloud Messaging → Apple app configuration and upload it with its Key ID and your Team ID. Without this, iOS devices get no pushes.
4. **Distribution certificate.** Make a signing request without touching Keychain:

   ```bash
   openssl req -new -newkey rsa:2048 -nodes -keyout dist.key -out dist.csr -subj "/CN=pux distribution"
   ```

   Under Certificates, add an **Apple Distribution** certificate from `dist.csr` and download `distribution.cer`. Then bundle it with the key:

   ```bash
   openssl x509 -inform DER -in distribution.cer -out dist.pem
   # Homebrew OpenSSL 3 needs -legacy so macOS can import the file; LibreSSL's openssl doesn't accept it.
   openssl pkcs12 -export -legacy -inkey dist.key -in dist.pem -out dist.p12
   ```

5. **Provisioning profiles.** Under Profiles, create two **App Store Connect** distribution profiles with the certificate from step 4. Name the one for `xyz.vidur.pux` "pux App Store" and the one for `xyz.vidur.pux.NotificationService` "pux NotificationService App Store". The names are informational: the workflow reads them from the files.
6. **App record.** In App Store Connect → Apps → New App: platform iOS, bundle ID `xyz.vidur.pux`, SKU `pux`. The name must be unique on the App Store, and you can change it later.
7. **API key for uploads.** In App Store Connect → Users and Access → Integrations → App Store Connect API, generate a team key with the **App Manager** role. Download the `.p8` (you can only download it once), and note the Key ID and the Issuer ID.
8. **Secrets.** From the directory holding the files:

   ```bash
   base64 -i dist.p12 | gh secret set IOS_DIST_CERT_P12_BASE64
   gh secret set IOS_DIST_CERT_PASSWORD          # the export password from step 4
   base64 -i pux_App_Store.mobileprovision | gh secret set IOS_APP_PROFILE_BASE64
   base64 -i pux_NotificationService_App_Store.mobileprovision | gh secret set IOS_EXTENSION_PROFILE_BASE64
   gh secret set APP_STORE_CONNECT_API_KEY < AuthKey_<KEY_ID>.p8
   gh secret set APP_STORE_CONNECT_KEY_ID --body <KEY_ID>
   gh secret set APP_STORE_CONNECT_ISSUER_ID --body <ISSUER_ID>
   ```

   Keep `dist.p12`, its password and the `.p8` files in a password manager, then delete the local copies.

The certificate and profiles expire after a year. Renew them by repeating steps 4, 5 and 8.

### After an upload

- The build shows up in App Store Connect → TestFlight once processing finishes, usually within half an hour.
- Each build asks about export compliance before anyone can install it. pux encrypts codes with libsodium, so read Apple's questions carefully. Once you know the answer, it can go in `Info.plist` as `ITSAppUsesNonExemptEncryption` so later builds skip the question.
- **Internal testing** (up to 100 members of your App Store Connect team) needs no review: add testers to an internal group.
- **External testing** needs Beta App Review the first time, plus test information and a privacy policy URL (`https://pux.vidur.xyz/privacy`).

## App Store screenshots

`lib/screenshots/` is a separate entry point that draws the store screenshots: branded scenes that mock a code arriving (lock screen, no signal, phone and computer), plus the real setup and forwarding screens in a phone frame. It never touches storage, the network or Firebase, and the shipped app doesn't include it. The scenes and their captions are in `lib/screenshots/scenes.dart`, in store order. The sender is a fictional "Northwind Bank", because App Review can reject screenshots that show a real bank's name.

```bash
cd mobile
ios/scripts/app_store_screenshots.sh            # writes build/app_store_screenshots/
```

The script needs Xcode with an iOS simulator runtime (`xcodebuild -downloadPlatform iOS`). It builds once, then opens every scene on its own 6.9" iPhone and 13" iPad simulators (the scene name goes in a file in the app's `tmp` directory, because Flutter on iOS can't read launch environment variables), with a clean Wi-Fi-only status bar, and checks each PNG is the size App Store Connect expects. To look at one scene while editing:

```bash
flutter run -t lib/screenshots/main.dart --dart-define=PUX_SCENE=noSignal
```

`test/screenshots_test.dart` lays out every scene at both sizes and fails on overflow.
