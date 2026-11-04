# Self-hosting pux

This runs the pux server and PostgreSQL with Docker Compose. You need a host that can receive mail on
port 25 (many residential ISPs and some cloud providers block it), a domain, and a TLS-terminating
reverse proxy for HTTPS.

## What self-hosting covers

- **Desktop apps (macOS, Linux)** work against your server without anything else: they get OTPs over a WebSocket.
- **Android and iOS push** go through Firebase Cloud Messaging. The published apps can only receive pushes
  sent with the pux Firebase project's credentials. For push on your own server you need your own Firebase
  project and your own app build. See [Mobile builds for your server](#mobile-builds-for-your-server).

## 1. DNS

| Record | Value |
|--------|-------|
| `A`/`AAAA` for `PHX_HOST` (e.g. `pux.example.com`) | your host |
| `MX` for `MAIL_DOMAIN` (defaults to `PHX_HOST`) | `PHX_HOST`, priority 10 |

Inbox addresses look like `<token>@MAIL_DOMAIN`. No SPF/DKIM records are needed, because the server only receives mail.

## 2. Configure

```bash
cd deploy
cp env.example .env       # .env is gitignored
$EDITOR .env              # fill in PHX_HOST, POSTGRES_PASSWORD and the secrets
```

Generate the secrets with `openssl rand -base64 48` (`SECRET_KEY_BASE`) and `openssl rand -base64 24` (the salts and the database password).

## 3. TLS

**HTTPS.** The server listens on `127.0.0.1:4000` and expects a reverse proxy (Caddy, nginx, Traefik…)
to terminate TLS for `PHX_HOST`. The proxy must forward WebSocket upgrades for `/ws/delivery` and set
`X-Forwarded-Proto: https` and `X-Forwarded-For`. The server redirects plain-HTTP requests to HTTPS and
trusts the last `X-Forwarded-For` hop only from private addresses.

**Don't log API paths at the proxy.** The record ID, a relay's only credential, is in the path of authenticated API calls (`/api/v1/records/:id`; [#18](https://github.com/vidurb/pux/issues/18) tracks removing it). The server leaves these paths out of its own logs, but anyone with your proxy's access logs could use a relay's API, including deleting it. Turn off access logging for `/api/v1/records/*`, or strip the path. Caddy doesn't log requests unless you add a `log` directive; nginx logs them by default.

Caddy example:

```
pux.example.com {
  reverse_proxy 127.0.0.1:4000
}
```

**SMTP STARTTLS.** Strongly recommended: without it, forwarded OTP emails cross the internet in
plaintext. Put a certificate and key for the MX hostname in `deploy/certs/`, readable by uid 65534
(`chmod 644`, or `chown 65534`). Then set:

```
SMTP_TLS_CERTFILE=/certs/fullchain.pem
SMTP_TLS_KEYFILE=/certs/privkey.pem
SMTP_REQUIRE_TLS=true
```

The server reads the certificate at start-up, so restart it (`docker compose restart server`) after renewing.

## 4. Run

```bash
docker compose up -d
docker compose logs -f server
curl -fsS https://pux.example.com/health
```

Database migrations run automatically on start. `PUX_VERSION` in `.env` pins the image tag: use a
release such as `0.1.0` in production, or `main` for the latest build of the main branch.

Check that mail reaches the server: create a relay in a desktop app (below), then send an email
containing `Your OTP is 123456` to its inbox address. Unsigned test mail shows as "(unverified)".

## Mobile builds for your server

The apps default to the server they were built for. To use yours:

- **Desktop:** build with `--dart-define=PUX_SERVER_URL=https://pux.example.com`, or import an
  enrollment JSON whose `server` is your URL (the app shows the server and asks before saving).
- **Android/iOS push:**
  1. Create a Firebase project.
  2. Run `flutterfire configure` in `mobile/`, as described in the main [README](../README.md#mobile).
  3. Build the app with `--dart-define=PUX_SERVER_URL=https://pux.example.com`.
  4. Put the project's service account JSON in `FCM_SERVICE_ACCOUNT_JSON`, on one line.

  iOS also needs an APNs key uploaded to Firebase.

## Upgrading and backups

```bash
docker compose pull && docker compose up -d
```

Read the [changelog](../CHANGELOG.md) before upgrading across minor versions. The database holds only
relays (public keys, inbox tokens), device push tokens and short-lived encrypted deliveries. Losing it
means users have to create new relays, but no OTPs or emails are ever stored. Back up the `db` volume
with `docker compose exec db pg_dump -U pux pux > pux.sql` if you'd rather not lose relays.
