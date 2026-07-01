# pux

Privacy-first OTP relay: receive bank OTP emails, parse the code in memory, end-to-end encrypt it, and push it to your devices.

## Architecture

- **server/** — Phoenix/Elixir service (inbound SMTP, marketing site, FCM push)
- **mobile/** — Flutter app (Android, iOS, macOS, Windows, Linux)

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

SMTP listens on port 2525 in dev (`SMTP_PORT`). HTTP on 4000.

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
| macOS / Windows / Linux | WebSocket + poll fallback | Import enrollment JSON only |

For FCM on mobile device builds, add `android/app/google-services.json` and `ios/Runner/GoogleService-Info.plist`, then run `flutterfire configure`, or pass Firebase values via `--dart-define=FIREBASE_*`.

Desktop clients register with `platform: "desktop"` and connect to `GET/DELETE /api/v1/records/:id/deliveries` and `WS /ws/delivery?token=<record_id>`.

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
| `SMTP_MAX_MESSAGE_SIZE` | no | Max inbound message bytes (default 1MB) |
| `SMTP_TLS_CERTFILE` / `SMTP_TLS_KEYFILE` | no | Enable inbound SMTP STARTTLS when both set |
| `FCM_SERVICE_ACCOUNT_JSON` | no | Firebase service account JSON for push |

### Mobile release signing

Copy `mobile/android/key.properties.example` to `mobile/android/key.properties` and create a release keystore. Without `key.properties`, release builds fall back to the debug keystore.

## Deployment

See [docs/deploy-emancipator.md](docs/deploy-emancipator.md) for homestacks / Emancipator alpha setup.

## License

AGPL-3.0 — see [LICENSE](LICENSE).
