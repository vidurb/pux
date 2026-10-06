# pux

Privacy-first OTP relay: receive bank OTP emails, parse the code in memory, end-to-end encrypt it, and push it to your devices.

## Architecture

- **server/** — Phoenix/Elixir service (inbound SMTP, marketing site, FCM push)
- **mobile/** — Flutter app (Android, iOS, macOS, Linux; Windows is not supported for now)

## Security model

- Encryption keypairs are generated on the mobile device; the private key never leaves the phone.
- The server stores only the client-supplied public key and encrypts OTP payloads with libsodium sealed boxes.
- Emails are parsed in memory and never stored.
- No accounts: a record ID is the only credential.
- New devices enroll in-app (`Create new relay` on mobile) or by scanning/importing a QR enrollment payload from an existing device. Desktop clients import enrollment JSON only (no key generation).
- Inbound SMTP validates recipient domains and caps message size.
- Push delivery is asynchronous (Oban) so SMTP responds immediately.

## Local development

### Server

```bash
cd server
mix deps.get
mix ecto.setup
mix phx.server
```

SMTP listens on port 2525 (`SMTP_PORT`) in every environment; map public port 25 to it. HTTP on 4000.

Tests need PostgreSQL (`DATABASE_URL`) and libsodium. The SMTP integration test talks to the real listener on port 2526 and the WebSocket tests to the endpoint on 4002.

Toolchain versions are pinned in [`.tool-versions`](.tool-versions) (Elixir 1.18.4 / OTP 27.3.4).

### Mobile

```bash
cd mobile
flutter pub get
flutter run
```

Set `PUX_SERVER_URL` via `--dart-define=PUX_SERVER_URL=http://10.0.2.2:4000` for the Android emulator.

Platform targets:

| Platform | Delivery | Onboarding |
|----------|----------|------------|
| Android | FCM push | Create relay or QR scan |
| iOS | FCM push (APNs) | Create relay or QR scan |
| macOS / Linux | WebSocket + poll fallback | Import enrollment JSON only |
| Windows | — | Not supported for now (does not build in CI) |

Without Firebase config the app still runs, but the home screen says push is not configured. To enable FCM, run `flutterfire configure --project=<id> --out=lib/src/firebase_options.dart --platforms=android,ios` in `mobile/` (this writes `android/app/google-services.json`, `ios/Runner/GoogleService-Info.plist` and replaces the placeholder options), or pass `--dart-define=FIREBASE_*` values. These files are not secret and can be committed.

#### Testing on an Android phone

1. Configure Firebase as above and make sure the server has the matching `FCM_SERVICE_ACCOUNT_JSON`.
2. Build and install: `flutter build apk --debug --dart-define=PUX_SERVER_URL=https://pux.vidur.xyz`, then `adb install build/app/outputs/flutter-apk/app-debug.apk` (or `flutter run -d <device> --dart-define=...`). CI also uploads a debug APK as the `pux-android-debug-apk` artifact of the `mobile` workflow, but it is built without Firebase config, so it cannot receive pushes.
3. Open the app, tap **Create new relay**, allow notifications, and forward a test email (`Your OTP is 123456`) to the inbox address shown.

To add a desktop, open the QR panel on the phone, tap **Copy enrollment JSON**, and paste it into the desktop app's **Import enrollment** screen. The JSON contains the private key.

Desktop clients register with `platform: "desktop"` and connect to `GET/DELETE /api/v1/records/:id/deliveries` and `WS /ws/delivery` with the record ID in the `x-pux-token` header (`?token=<record_id>` still works but lands in proxy logs).

Decrypted push payloads are JSON with a `type`:

- `otp`: `otp`, `sender`, `received_at`, `parser`
- `forward_confirm`: `code`, `url`, `sender`, `forwarding_from`, `received_at` (Gmail forwarding confirmation; confirm with the code or link to finish forwarding setup)

## Production environment variables

### Server

| Variable | Required | Description |
|----------|----------|-------------|
| `DATABASE_URL` | yes | PostgreSQL connection string |
| `SECRET_KEY_BASE` | yes | Phoenix secret |
| `LIVE_VIEW_SIGNING_SALT` | yes | LiveView WebSocket signing salt |
| `COOKIE_SIGNING_SALT` | yes | Session cookie signing salt |
| `PHX_HOST` | no | Public hostname (default `pux.vidur.xyz`) |
| `MAIL_DOMAIN` | no | SMTP recipient domain |
| `SMTP_PORT` | no | SMTP listen port (default `2525`; the image runs as non-root) |
| `SMTP_MAX_MESSAGE_SIZE` | no | Max inbound message bytes (default 1MB) |
| `SMTP_MAX_CONNECTIONS` | no | Max concurrent SMTP connections (default 100) |
| `SMTP_MAX_CONNECTIONS_PER_IP` | no | Max concurrent SMTP connections per client IP (default 5) |
| `SMTP_TLS_CERTFILE` / `SMTP_TLS_KEYFILE` | no | Enable inbound SMTP STARTTLS when both set |
| `FCM_SERVICE_ACCOUNT_JSON` | no | Firebase service account JSON for push |

### Mobile release signing

Copy `mobile/android/key.properties.example` to `mobile/android/key.properties` and create a release keystore. Without `key.properties`, release builds fall back to the debug keystore.

## Deployment

See [docs/deploy-emancipator.md](docs/deploy-emancipator.md) for homestacks / Emancipator alpha setup.

## License

AGPL-3.0 — see [LICENSE](LICENSE).
