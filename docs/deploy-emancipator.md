# Deploying pux on Emancipator (homestacks alpha)

## Prerequisites

1. **GitHub repo** `vidurb/pux` with CI publishing `ghcr.io/vidurb/pux-server:main`.
2. **Firebase project** with FCM enabled; paste the service-account JSON into
   `clusters/emancipator/pux-system/secrets/01-pux-secrets.secret.yaml` (`FCM_SERVICE_ACCOUNT_JSON`), then `sops -e -i` the file.
3. **Oracle Cloud security list** on Emancipator: allow inbound TCP **25** to the node (`80.225.230.149`).
4. **DNS** (external-dns + manual MX):
   - `pux.vidur.xyz` A → `80.225.230.149` (via emancipator-gateway annotation)
   - `mail.pux.vidur.xyz` A → `80.225.230.149` (via `pux-smtp` service annotation)
   - **MX** `pux.vidur.xyz` → `mail.pux.vidur.xyz` priority 10 (create manually in Route53 if external-dns does not manage MX)

## homestacks wiring

The app lives at `projects/pux` (git submodule → `https://github.com/vidurb/pux.git`).

Flux paths:

- `clusters/emancipator/pux-system/database` — CloudNativePG `pux-pg`
- `clusters/emancipator/pux-system/install` — namespace, deployment, secrets
- `clusters/emancipator/pux-system/routing` — HTTPRoute `pux.vidur.xyz`

Image automation on Sinkhole tracks `ghcr.io/vidurb/pux-server:main`.

## Server secrets (production)

Add to the deployment secret (in addition to existing values):

| Key | Purpose |
|-----|---------|
| `LIVE_VIEW_SIGNING_SALT` | LiveView signing salt (random 16+ chars) |
| `COOKIE_SIGNING_SALT` | Session cookie salt (random 16+ chars) |
| `SMTP_MAX_MESSAGE_SIZE` | Optional; default `1048576` |
| `SMTP_TLS_CERTFILE` / `SMTP_TLS_KEYFILE` | Optional inbound SMTP TLS |

Push delivery is asynchronous via Oban (`:push` queue). SMTP returns `250 OK` after enqueueing jobs.

## SMTP ingress

The deployment binds **hostPort 25** on the Emancipator node so inbound mail reaches the Phoenix `gen_smtp` listener directly. HTTP stays on kgateway (`pux.vidur.xyz` → port 4000).

Only recipients at the configured `MAIL_DOMAIN` are accepted.

## Email forwarding

Create a relay in the mobile app (`Create new relay`), then forward bank OTP emails to the assigned inbox address, e.g. `abc123xyz@pux.vidur.xyz`.

Security details and setup instructions are at `https://pux.vidur.xyz/signup`.

## Mobile alpha (Android)

1. Create a Firebase Android app for `xyz.vidur.pux`.
2. Run `flutterfire configure` in `mobile/` (or copy `google-services.json` to `mobile/android/app/`).
3. The Google Services Gradle plugin applies automatically when `google-services.json` is present.
4. For release builds, create a keystore and `mobile/android/key.properties` (see `key.properties.example`).
5. Build: `cd mobile && flutter build apk --dart-define=PUX_SERVER_URL=https://pux.vidur.xyz`
6. Open the app, tap **Create new relay**, and grant notification permission.

Release APKs block cleartext HTTP except localhost / emulator (`10.0.2.2`).

## Mobile alpha (iOS)

See [mobile/ios/README.md](../mobile/ios/README.md). iOS uses the same FCM data-message flow as Android.

## Desktop alpha (macOS / Windows / Linux)

1. Create a relay on a mobile device and export the enrollment JSON from the home-screen QR payload.
2. Run the desktop app: `flutter run -d macos` (or `-d windows` / `-d linux`).
3. Choose **Import enrollment** and paste the JSON.
4. Desktop clients receive OTPs via WebSocket (`/ws/delivery`) with poll fallback (`GET/DELETE /api/v1/records/:id/deliveries`).

Desktop builds do not generate keys or create relays.

## Verification checklist

- [ ] `curl https://pux.vidur.xyz/health` returns `{"status":"ok"}`
- [ ] `nc -zv mail.pux.vidur.xyz 25` connects
- [ ] Mobile app creates a relay and shows an inbox address
- [ ] Test email with body `Your OTP is 123456` triggers a decrypted notification
- [ ] Stale records pruned after `record_ttl_days` (default 90)
