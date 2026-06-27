# pux

Privacy-first OTP relay: receive bank OTP emails, parse the code in memory, end-to-end encrypt it, and push it to your devices.

## Architecture

- **server/** — Phoenix/Elixir service (inbound SMTP, LiveView signup, FCM/APNs push)
- **mobile/** — Flutter app (Android-first; iOS scaffolded)

## Security model

- Emails are parsed in memory and never stored.
- OTP payloads are encrypted with libsodium sealed boxes; the server only holds the public key.
- No accounts: a record ID (from the enrollment QR) is the only credential.
- New devices enroll by scanning a QR from an existing device.

## Local development

### Server

```bash
cd server
mix deps.get
mix ecto.setup
mix phx.server
```

SMTP listens on port 2525 in dev (`SMTP_PORT`). HTTP on 4000.

### Mobile

```bash
cd mobile
flutter pub get
flutter run
```

Set `PUX_SERVER_URL` via `--dart-define=PUX_SERVER_URL=http://10.0.2.2:4000` for the Android emulator.

## Deployment

See [docs/deploy-emancipator.md](docs/deploy-emancipator.md) for homestacks / Emancipator alpha setup.

## License

AGPL-3.0 — see [LICENSE](LICENSE).
