# Native app migration plan

## Goal and scope

Replace the Flutter client with native Android, iOS, macOS and Linux apps while preserving the server protocol, security properties and user workflows. Windows is not currently supported. Keep `mobile/` and existing release paths until each replacement has passed its cutover gates. Use independent platform directories under `native/`, so platform work can proceed independently; coordinate any shared files and CI integration after review.

## Current behavior to preserve

- Phones create relays, scan or import enrollment, display and copy enrollment QR/JSON, show the inbox and server status, send a test code, remove this device or delete a relay, and explain forwarding and notification/background restrictions. Desktop imports enrollment JSON and provides equivalent management where applicable. Inspect `mobile/lib/src/screens/` and its tests for details and states.
- Enrollment v1 contains `record_id`, `public_key`, `private_key`, `inbox`, and optional `server`. Keys are 32-byte unpadded base64url; the record ID is a UUID. Validate server URLs and ask the user to confirm the host before saving. Imported servers require HTTPS except the existing local development exceptions. Protect partial writes and never log secrets.
- The server encrypts payloads with libsodium sealed boxes. Preserve wire compatibility, base64url handling, payload validation and notification behavior; use `mobile/lib/src/services/crypto_service.dart`, `notification_service.dart`, the iOS extension, server code and existing tests as the specification. Generate cross-client test vectors and test malformed ciphertext and keys.
- HTTP uses `/api/v1`, Bearer record ID authentication, and the create, register, delete, pending delivery, acknowledge, health and test endpoints documented in README. Preserve error and rate-limit handling. Never put the credential in a URL.
- Android and iOS register the Firebase Installation ID as `platform: fcm`, persist the returned device ID and reuse it on registration. Android handles data messages; iOS uses the APNs alert and notification service extension with the shared keychain group and generic fallback. Preserve permission and token refresh behavior.
- Desktop registers as `platform: desktop`, polls pending deliveries and connects to `/ws/delivery` with `x-pux-token`; reconnect, deduplicate and re-register every 12 hours. Match the existing held/recent-code, notification permission, retry, expiry and acknowledgment rules in `desktop_delivery_service.dart`, including failure and offline cases. Plaintext codes stay in memory only.
- Preserve secure storage, clipboard handling, notification privacy, URL allowlisting, removal and logout semantics, and platform-specific background restrictions. Check the existing platform runners and tests rather than assuming platform APIs behave alike.

## Platform work

1. **Android:** Kotlin, Jetpack Compose, Android Keystore-backed storage, Firebase Messaging/Installations, camera QR scanning and native notifications. Preserve the package ID, backup exclusion, lock-screen privacy, background guidance and sensitive clipboard behavior. Investigate Flutter secure-storage v11 compatibility on an actual upgrade; implement a verified migration or clearly document a safe re-enrollment path before release.
2. **iOS:** Swift and SwiftUI with native Firebase, camera scanning, shared Keychain and a notification service extension. Preserve bundle and extension identifiers, entitlements and first-unlock accessibility. Test migration from released Flutter keychain entries and APNs/FCM behavior on a physical device.
3. **macOS:** Swift and SwiftUI/AppKit, Keychain, native notifications, menu-bar lifecycle, login item and desktop delivery. Preserve existing supported macOS versions, signing identity and settings. Verify upgrade access to Flutter Keychain data and app identity.
4. **Linux:** native GTK app with Secret Service, D-Bus notifications and desktop delivery; preserve the currently supported distro/glibc baseline and package formats. Verify Secret Service item compatibility or provide a safe re-enrollment path, including missing keyring and notification daemon behavior.

Each platform owns only its `native/<platform>/` implementation in its isolated worktree. Use existing branding. Do not remove or change Flutter, server, release metadata or shared CI in these parallel branches. Record dependencies, setup, build and test commands and any parity gaps in the platform directory. Do not claim a feature works without testing it.

## Phases and acceptance

1. Scaffold buildable, runnable projects and automated tests, with configuration for the server and Firebase where relevant. Establish deterministic protocol/crypto fixtures from the existing client and server.
2. Implement enrollment, secure persistence and API/error handling; verify compatible enrollment exchange and safe upgrade or explicit re-enrollment. Never overwrite existing enrollment until migration succeeds.
3. Implement delivery, notifications, lifecycle and security behavior, then the remaining user flows and platform integration. Port meaningful existing tests and add protocol, failure, persistence and lifecycle coverage alongside implementation.
4. Integrate reviewed platform changes, add platform CI and packaging/signing workflows, and update documentation. Run unit/integration suites, cross-client interoperability against the server, and physical-device push/upgrade tests. Validate Linux and macOS notification failure and reconnection scenarios.
5. Cut over each platform only after feature parity, upgrade/re-enrollment, signing, release artifacts, rollback and real delivery are verified. Keep Flutter releases available until all targets pass. Remove Flutter and obsolete tooling only after the last cutover.

## Open integration decisions

Native platform code may duplicate protocol logic initially; consolidate only after tested compatibility is established. Exact secure-storage migration, Firebase configuration, signing credentials, Linux toolkit dependencies and hardware/OS coverage must be verified rather than assumed. A failed migration must not silently create a new relay or erase keys. Hardware, credentials and unavailable platform SDKs are explicit release blockers, not reasons to report parity as complete.
