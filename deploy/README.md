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

### SMTP behind a TCP proxy

The server limits concurrent SMTP connections per client IP (`SMTP_MAX_CONNECTIONS_PER_IP`, default 5;
IPv6 clients are counted per /64). It sees the address of whoever opened the TCP connection, and it
doesn't support the PROXY protocol. So if port 25 reaches the server through a TCP proxy or load
balancer (HAProxy, nginx `stream`, a cloud load balancer in TCP mode, Docker's userland proxy, a tunnel),
every connection seems to come from the proxy, and the per-IP limit turns into a cap of 5 connections in
total. Either:

- **Preserve the client IP,** for example with a load balancer in pass-through mode or a plain port
  forward (the Compose `ports:` mapping keeps it for IPv4 when Docker uses iptables, its default), or
- **Turn the per-IP limit off** with `SMTP_MAX_CONNECTIONS_PER_IP=0` in `.env`. An empty value counts as
  unset and gives the default, so it has to be `0`.

`SMTP_MAX_CONNECTIONS` (default 100) still caps connections in total, and the per-relay delivery limit
(`SMTP_INBOUND_RATE_LIMIT`) still applies, so a mail flood can't push unlimited OTPs either way.

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

## Data retention

The [main README](../README.md#data-retention) has the rules, and `:pruner` in `server/config/config.exs`
has the numbers. Relays and phones aren't removed for being quiet until `device_max_idle_days` (2 years), so
the tables grow with installs rather than with use. What this means when you run the server:

- **Without `FCM_SERVICE_ACCOUNT_JSON`** the server can't learn that a phone has gone, so an `fcm` device stays
  until the 2-year limit or until someone deletes the relay. Desktop devices still age out after 90 days.
- **Keep `device_max_idle_days` and your published retention text in step** if you change it.
- **After switching Firebase project,** old tokens get a 403 on every send and are not removed, because wrong
  credentials look exactly the same and must not delete every device. Apps from the new project register
  fresh tokens, and the old rows stay until the 2-year limit or until the relay is deleted.
- **Deletion requests** can be handled from the inbox address alone. Its token is the part before the `@`:
  `docker compose exec db psql -U pux pux -c "DELETE FROM records WHERE inbox_token = '<token>'"`.
  Devices and pending deliveries go with the record.
