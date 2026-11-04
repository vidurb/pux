# Security policy

pux relays one-time passwords, so security reports are the highest-priority issues in this project.

## Reporting a vulnerability

Please **do not open a public issue**. Report privately through GitHub:
[**Report a vulnerability**](https://github.com/vidurb/pux/security/advisories/new)
(Security tab → Advisories → Report a vulnerability).

Include what you found, how to reproduce it, and the impact you expect. You should get an
acknowledgement within 3 working days and an assessment within 10. Fixes for confirmed issues are
released as soon as they are ready, and the advisory is published once users have had a chance to
update. Reporters are credited unless they ask not to be.

## Supported versions

pux is pre-1.0. Only the latest release, and the `main` branch, receive security fixes.

| Component | Supported |
|-----------|-----------|
| Server (`ghcr.io/vidurb/pux-server`) | latest release and `main` |
| Apps (Android, iOS, macOS, Linux) | latest release |

## Scope

In scope:

- The server in `server/`: inbound SMTP, OTP parsing, DKIM verification, the HTTP API, the delivery WebSocket, push dispatch.
- The apps in `mobile/`: key generation and storage, decryption, enrollment (QR / JSON import), notifications and clipboard handling, the iOS notification service extension.
- The build and release pipeline in `.github/` and `server/Dockerfile`.
- The hosted instance at `pux.vidur.xyz`. Don't degrade it for other users while testing: no load testing, no spam, and only use relays you created yourself.

Out of scope:

- Weaknesses in a self-hosted deployment's own configuration (DNS, TLS, reverse proxy, secrets).
- Attacks that need an already-compromised or rooted/jailbroken device, or physical access to an unlocked device.
- Mail providers' forwarding behaviour, and the security of the bank emails themselves.

## Security model

What pux is designed to guarantee, so you can tell a vulnerability from intended behaviour:

- **The server cannot read OTPs.** Keypairs are generated on the device. The server stores only the
  public key, seals each payload with a libsodium sealed box and keeps no mail. Plaintext exists on
  the server only in memory, while a message is being parsed.
- **The record ID is the only credential.** It is a random UUID sent only in request headers: as a bearer
  token to the API, and in `x-pux-token` to the delivery WebSocket. It is never in a URL. A record ID alone
  lets someone use the relay's API, including deleting it. Reading its OTPs also needs the private key:
  anyone holding both (the enrollment QR / JSON) can read that relay's OTPs.
- **Sender names are only shown as verified when DKIM says so.** A bank label is shown only when a valid
  DKIM signature aligns with the From domain; anything else is marked unverified. DKIM doesn't stop a
  genuinely signed message from being replayed to another inbox address.
- **Inbox addresses are unguessable but not secret.** Anyone who learns an address can send mail to it;
  per-inbox rate limits and sender verification limit what they can do with it.
