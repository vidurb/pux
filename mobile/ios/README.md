# pux iOS

iOS uses Firebase Cloud Messaging (FCM delivers via APNs under the hood), mirroring the Android push flow.

## Setup

1. Create a Firebase iOS app for bundle id `xyz.vidur.pux`.
2. Run `flutterfire configure` in `mobile/` (or copy `GoogleService-Info.plist` to `ios/Runner/`).
3. Enable Push Notifications capability in Xcode for the Runner target.
4. Upload your APNs key/certificate to the Firebase console.

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
