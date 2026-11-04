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
