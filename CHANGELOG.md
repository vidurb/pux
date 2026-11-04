# Changelog

All notable changes to pux are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). The server and apps share one version number.

## [Unreleased]

### Security

- Server: DKIM verification of inbound mail (rsa-sha256 and ed25519-sha256). A bank's name is shown only when a signature aligned with the From domain verifies; other senders are marked unverified. Gmail forwarding confirmations are only relayed when Google's signature verifies.
- Server: the OTP parser caps its input and runs in linear time, and classification has a 5 s timeout, so a single large or hostile email can no longer pin a CPU.
- Server: per-inbox delivery rate limit (`SMTP_INBOUND_RATE_LIMIT`), per-relay API rate limit (`RECORD_API_RATE_LIMIT`) and a device cap per relay (`MAX_DEVICES_PER_RECORD`).
- Server: optional `SMTP_REQUIRE_TLS` to refuse mail before STARTTLS, and a boot warning when no SMTP TLS certificate is configured.
- Server: the delivery WebSocket only accepts the record ID in the `x-pux-token` header; the `?token=` query parameter is no longer accepted, so the credential stays out of URLs and proxy logs.
- Server: updated Bandit, jose, plug_crypto and decimal to clear 24 published advisories. Added a strict Content-Security-Policy.
- Apps: OTP notifications are hidden on a secure Android lock screen. Copied codes and enrollment JSON are marked sensitive and cleared from the clipboard after a minute (except on iOS).
- Android: app backups and device-to-device transfer are disabled, so keys never leave the device that way. Release builds refuse to fall back to the debug signing key.
- Apps: imported or scanned enrollments must point at an `https` server, and the app shows the server before saving.
- CI: GitHub Actions pinned to commit SHAs, least-privilege workflow permissions, `mix deps.audit` and Sobelow checks, Dependabot.

### Added

- `DELETE /api/v1/records/:id` and `DELETE /api/v1/records/:id/devices/:device_id`. The app's reset menu offers **Remove this device** and **Delete relay everywhere**.
- iOS: OTPs arrive as alert pushes that a notification service extension decrypts on the device, so they show even when the app has been force-quit.
- Self-hosting with Docker Compose (`deploy/`), and a release workflow that publishes versioned server images and app builds.

### Changed

- Payloads include `verified` and `sender_domain`, and unverified senders are shown as "OTP from <domain> (unverified)".
- Phoenix 1.8, Phoenix LiveView 1.2, Hammer 7, Oban 2.24.
- iOS requires 15.0 or later, and the iOS build uses Swift Package Manager instead of CocoaPods.

### Fixed

- The OTP parser no longer crashes on bodies that aren't valid UTF-8, or on codes near multi-byte characters such as `₹`.
- An SMTP session no longer crashes if its relay is deleted while mail is being delivered.
- Acknowledging a desktop delivery no longer races with a concurrent acknowledgement.
- Inbox addresses are generated without modulo bias.
