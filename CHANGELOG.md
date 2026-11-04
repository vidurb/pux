# Changelog

All notable changes to pux are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). The server and apps share one version number.

## [Unreleased]

### Security

- Server: DKIM verification of inbound mail (rsa-sha256 and ed25519-sha256). A bank's name is shown only when a signature aligned with the From domain verifies; other senders are marked unverified. Gmail forwarding confirmations are only relayed when Google's signature verifies.
- Server: the OTP parser caps its input and runs in linear time, and classification has a 5 s timeout, so a single large or hostile email can no longer pin a CPU.
- Server: per-inbox delivery rate limit (`SMTP_INBOUND_RATE_LIMIT`), per-relay API rate limit (`RECORD_API_RATE_LIMIT`) and a device cap per relay (`MAX_DEVICES_PER_RECORD`).
- Server: a per-IP limit on failed authentication for the API and the delivery WebSocket (`AUTH_FAILURE_RATE_LIMIT`), so unknown tokens can't cause unlimited database lookups. Over the limit, an IP gets 429 without a lookup until the minute ends. Malformed tokens never reach the database and don't count.
- Server: optional `SMTP_REQUIRE_TLS` to refuse mail before STARTTLS, and a boot warning when no SMTP TLS certificate is configured.
- Server: the delivery WebSocket only accepts the record ID in the `x-pux-token` header; the `?token=` query parameter is no longer accepted, so the credential stays out of that URL.
- Server: the REST API identifies a relay from the `Authorization` header alone, so the record ID no longer appears in any URL and a reverse proxy that logs paths doesn't capture it. Authenticated routes moved from `/api/v1/records/:id/...` to `/api/v1/record/...`, with no compatibility period. A token that matches no record now gets 401 on every route, and these requests now appear in the server's request log.
- Server: record IDs, inbox tokens, push tokens and email contents no longer reach the logs, including through delivery error messages, the HTTPS redirect line and crash reports. A malformed `FCM_SERVICE_ACCOUNT_JSON` is no longer echoed in the error either. When the database fails during inbound SMTP, the server now replies `451` so the sender retries, instead of dropping the connection.
- Server: updated Bandit, jose, plug_crypto and decimal to clear 24 published advisories. Added a strict Content-Security-Policy.
- Apps: OTP notifications are hidden on a secure Android lock screen. Copied codes and enrollment JSON are marked sensitive and cleared from the clipboard after a minute (except on iOS).
- Android: app backups and device-to-device transfer are disabled, so keys never leave the device that way. Release builds refuse to fall back to the debug signing key.
- Apps: imported or scanned enrollments must point at an `https` server, and the app shows the server before saving.
- CI: GitHub Actions pinned to commit SHAs, least-privilege workflow permissions, `mix deps.audit` and Sobelow checks, Dependabot.

### Added

- A logo and identity (`brand/`), used for the website, favicons and app icons. The name is written `pux`, lowercase, everywhere.
- Website: a new landing page at `/` covering how pux works, the security model and its limits, supported banks, an FAQ and self-hosting. `/signup` now redirects there. The page sets no cookies and loads no scripts.
- Website: `/privacy` and `/terms` pages, Open Graph and Twitter cards, favicons and `/.well-known/security.txt`.
- Apps: new icons on Android (adaptive, themed and notification), iOS and macOS, plus a splash screen.
- `DELETE /api/v1/record` and `DELETE /api/v1/record/devices/:device_id`. The app's reset menu offers **Remove this device** and **Delete relay everywhere**.
- iOS: OTPs arrive as alert pushes that a notification service extension decrypts on the device, so they show even when the app has been force-quit.
- Android: the home screen, including right after setup, warns when codes could silently stop arriving, either because Android 12+ can hibernate pux after months without use or because its background battery use is restricted, and links to the settings page that fixes it. A warning goes away once the setting changes. If dismissed, it returns only after the setting has been fixed and then undone, or after setting up pux again.
- Apps: on Android, iOS and macOS, the home screen warns when notifications are off, when the Android "OTP codes" category is off, or when iOS or macOS delivers them without an alert, and links to the settings page that fixes it. It goes away once the setting changes and can't be dismissed while the problem lasts, because without notifications codes are lost. The home screen now shows one setup prompt at a time, with this one first.
- Self-hosting with Docker Compose (`deploy/`), and a release workflow that publishes versioned server images and app builds.

### Changed

- Server: **retention no longer depends on quietness for relays and phones.** A phone stays registered until FCM reports its token dead or it goes 2 years with no registration and no accepted push, instead of 30 days, and a relay stays while it has a device, then for 30 days after losing the last one, instead of 90 days from its last activity. As a result the server keeps inbox tokens, public keys and push tokens for as long as an app stays installed, up to that limit; see [Data retention](README.md#data-retention). Desktop devices age out after 90 days without registering, up from 30. The `:pruner` settings are now `device_max_idle_days`, `desktop_device_ttl_days`, `deviceless_record_ttl_days` and `fcm_token_check_days`.
- Server: mail to a relay with no devices now bounces at `RCPT` with the same `550 5.1.1` as an unknown address, instead of being accepted and dropped, so the sender's bounce shows that something is wrong.
- Payloads include `verified` and `sender_domain`, and unverified senders are shown as "OTP from <domain> (unverified)".
- Phoenix 1.8, Phoenix LiveView 1.2, Hammer 7, Oban 2.24.
- iOS requires 15.0 or later, and the iOS build uses Swift Package Manager instead of CocoaPods.
- The server image is built and run on Alpine 3.24 (OpenSSL 3.5, libsodium 1.0.22).
- Updated the app's Firebase, flutter_local_notifications, Riverpod and no_screenshot dependencies to their current major versions. flutter_secure_storage stays on v10 so existing Android installs keep their keys.

### Fixed

- A phone that went 30 days without an OTP or being opened no longer loses its registration and silently misses the next code, and a relay that went 90 days without one no longer starts bouncing the bank's forwarded mail.
- Server: tokens FCM rejects as malformed are removed like unregistered ones, and a dry-run check finds dead tokens on relays that get no mail. A 404 that doesn't name the token (a wrong project ID, a proxy) no longer removes the device.
- Desktop: an app left running re-registers every 12 hours, so it can't age out while connected.
- macOS: a code that arrives while notifications are off is no longer lost. It stays on the server until it expires, up to 15 minutes after arriving, can be read on the home screen in the meantime, and appears as a notification once they're allowed again. Decrypted codes are kept in memory only. Linux and Windows have no setting pux can read, so the OS can still drop a code there unnoticed.
- The OTP parser no longer crashes on bodies that aren't valid UTF-8, or on codes near multi-byte characters such as `₹`.
- An SMTP session no longer crashes if its relay is deleted while mail is being delivered.
- Acknowledging a desktop delivery no longer races with a concurrent acknowledgement.
- Apps: leaving an enrollment screen while its request is running can no longer lose the result. Back is disabled until the request finishes, the app reaches the home screen and starts delivery without a restart, and failures are always shown. A new relay that can't be saved on the device is deleted from the server.
- Apps: a failed notification permission request no longer shows as a connection failure or stops the device from registering.
- Inbox addresses are generated without modulo bias.
- A delivery WebSocket connected with an uppercase record ID now receives its deliveries.
