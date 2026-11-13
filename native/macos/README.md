# pux macOS (Native)

A native Swift and SwiftUI/AppKit desktop client for pux on macOS. It replaces the Flutter desktop wrapper with a native implementation targeting macOS 12.0+, preserving full protocol compatibility, cryptographic verification, wire format, menu-bar lifecycle, and desktop delivery semantics.

## Architecture

- **`Sources/PuxCore/`**: Core logic and platform services.
  - **`Crypto/`**: Libsodium sealed box encryption (`crypto_box_seal` / `crypto_box_seal_open`), 32-byte keypair generation, and unpadded base64url encoding.
  - **`Storage/`**: Secure storage backed by the macOS Data Protection Keychain (generic password service `flutter_secure_storage_service`), maintaining compatibility with existing Flutter keychain data. Includes rollback protection on partial enrollment writes. Surfaces explicit errors without clearing state on read failures.
  - **`Network/`**: HTTP API client (`/api/v1/records`, `/api/v1/record/devices`, `/api/v1/record/deliveries`, `/api/v1/record/test`, `/health`) and WebSocket client (`/ws/delivery` with `x-pux-token` header).
  - **`Delivery/`**: `DesktopDeliveryService` implementing polling on connect/reconnect (background; does not gate WebSocket setup), candidate ID snapshotting to prevent poll/WebSocket arrival races, serialized reconnect backoff, immediate device registration with exponential retry, post-subscription poll (background task), bounded WebSocket ping handshake (`WebSocketHandshakeOutcome` retains deferred frames on every failure reason), socket supervision decoupled from delivery handling (pongs on the receive path; envelopes on per-session per-delivery serial queues with handle-time dedup), session-scoped `reportError`, 30s keep-alive with bounded ping sends, deduplication, bounded notification permission checks at presentation and acknowledgement (30s timeout holds without ack/presentation; flush retries), same-session same-ID retry bypasses stalled permission work, notification permission tracking, held deliveries in memory (15-minute expiry; timer purges on its own cadence and schedules flush and server poll on separate background tasks; flush re-checks expiry before present/ack; permission checks reject stale explicit sessions and advance epoch on stop/resume; `flushHeld` is owned per session/epoch; the current session can take over from a stale owner while late stale work is gated by ownership checks; hold flush/poll task slots are installed under the service lock with schedule tokens), an unacknowledged delivery retry queue that retries on its own (exponential backoff from 2s to 60s, at most ten rounds per series, restarted by each new failure, poll, reconnect or session start; owned by the session that scheduled it, so `stop()`, `clear()` and relay or device removal cancel it and a replaced task cannot release its successor's slot), and session-guarded task cancellation.
  - **`Notification/`**: `NotificationService` (handling `UNUserNotificationCenter` presentation and `copy_code` action) and `NotificationPermissions` (tracking `allowed`, `off`, `notAsked`, and `quiet`). OTP codes appear in the notification body (matching Flutter). Copy actions read from an in-memory TTL store (`NotificationCodes`); codes are not placed in notification `userInfo`.
  - **`Shell/`**: `DesktopShell` (managing `NSStatusItem` with `MenuBarIcon`, window close-to-hide behavior, and UserDefaults settings `desktop.closeQuits` / `desktop.startHidden`), `LaunchAtLogin` (supporting macOS 12+), and `SensitiveClipboard` (using `NSPasteboard` with `org.nspasteboard.ConcealedType` auto-clearing after 60 seconds).
- **`Sources/PuxApp/`**: Native SwiftUI application UI.
  - **`ContentView`**: Root view with blocking, retryable keychain error view (`Keychain Storage Error`) when storage access fails, preventing accidental display of initial enrollment screens on storage errors.
  - **`HomeScreenView`**: Real-time status banners, server health, held codes list with copy buttons, inbox display, enrollment JSON export, test code dialog with error handling and retry, and device removal / relay deletion with safety checks.
  - **`EnrollChooserScreenView`** & **`ImportEnrollmentView`**: Import enrollment JSON with confirmation of untrusted server hosts (`ConfirmServerDialog`) prior to saving. Non-blocking local import dismisses modal immediately while network connects in background.
  - **`DesktopSettingsView`**: Settings for launch at login (with macOS 12 and 13+ support), menu-bar-only launch, and close-quits behavior.
  - **`ForwardingHelpView`**: Step-by-step forwarding instructions for Gmail, Outlook, and known bank senders.
  - **`NotificationExplainerView`**: Explains notification requirements before prompting for permissions.
  - **`DeleteRelayDialog`**: In-dialog progress indicator and inline error reporting to prevent data loss on server failure.
- **`Sources/Clibsodium/`**: Module map integrating libsodium.
- **`Vendor/libsodium/`**: Universal fat binary (`x86_64` and `arm64`) compiled targeting `macOS 12.0` (`minos 12.0`), bundled into release builds without Homebrew dependencies or linker deployment target warnings.
- **`Tests/PuxTests/`**: Automated unit and integration test suite (156 XCTest cases as of this worktree). `scripts/test.sh` runs `KeychainAppProbeTests` first (non-production service); signed release builds can also run `pux.app/Contents/MacOS/pux --probe-keychain` for a live round-trip (unbundled `swift run` lacks keychain entitlements).
- **`Resources/`**: `Info.plist`, `Release.entitlements`, `DebugProfile.entitlements`, and `Assets.xcassets` (including `AppIcon` and `MenuBarIcon`).
- **`scripts/`**: Build, test, bundle, and signing scripts.

## Dependencies and Setup

### Prerequisites

- **macOS 12.0 (Monterey) or later** (matching the repository baseline)
- Swift 5.9+ / Xcode 15+
- `libsodium` (pre-bundled universal binary in `Vendor/libsodium/`, or via Homebrew `brew install libsodium pkg-config`)

### Build and Test

Run the test suite:
```bash
./native/macos/scripts/test.sh
# or:
swift test --package-path native/macos --disable-sandbox
```

Build the release executable:
```bash
./native/macos/scripts/build.sh
# or:
swift build --package-path native/macos -c release --disable-sandbox
```

Create the application bundle (`pux.app`):
```bash
./native/macos/scripts/bundle_app.sh release
```
`bundle_app.sh` compiles `Assets.xcassets` with `actool` (verifying `AppIcon.icns` and `Assets.car`), bundles the universal macOS 12.0 `libsodium.26.dylib` inside `pux.app/Contents/Frameworks/`, adjusts dynamic linker IDs to `@rpath/libsodium.26.dylib`, sets `@executable_path/../Frameworks` in the binary rpath, and signs the bundle so the resulting `.app` is completely self-contained and portable across Macs without Homebrew.

Sign the application bundle for local testing (ad-hoc):
```bash
./native/macos/scripts/sign_app.sh native/macos/build/pux.app -
```

For release distribution with Developer ID and Keychain access group:
```bash
./native/macos/scripts/sign_app.sh native/macos/build/pux.app "Developer ID Application: <Name> (<TEAM_ID>)" <TEAM_ID> <profile.provisionprofile>
```

Verify bundled app execution:
```bash
./native/macos/build/pux.app/Contents/MacOS/pux --check
```

## macOS 12 Support and Launch-at-Login Fallback

The app targets macOS 12.0+ (`.macOS(.v12)` in `Package.swift` and `LSMinimumSystemVersion = 12.0` in `Info.plist`).
- **macOS 13+ (Ventura and newer)**: Uses `SMAppService.mainApp` to register, unregister, and query login status, and deep-links to System Settings → General → Login Items.
- **macOS 12 (Monterey)**: Automatic login-item registration is unavailable under the hardened runtime/sandbox. **Desktop settings** shows an honest manual path via **Open Users & Groups** (`x-apple.systempreferences:com.apple.preferences.users`).

`bundle_app.sh` builds a universal `pux` binary (`lipo` of arm64 and x86_64 slices), injects `CFBundleShortVersionString` from `.release-please-manifest.json` and `CFBundleVersion` from `PUX_BUILD_NUMBER` or `GITHUB_RUN_NUMBER` (release CI must set this), strips absolute toolchain `LC_RPATH` entries, and verifies the vendored libsodium SHA-256 from `Vendor/libsodium/PROVENANCE.md`.

## Review Findings and Resolution Matrix

The following records changes made in response to independent reviews in thread `thr_pm8pammefe`. Tests provide targeted evidence; platform behavior listed below remains unverified:

| Finding | Severity | Issue | Resolution in `native/macos/` | Regression Test Coverage |
| :--- | :---: | :--- | :--- | :--- |
| **Keychain Access Group Mismatch** | **P1** | Released Flutter desktop client  only configures `<TEAM_ID>.xyz.vidur.pux` (no `.shared` group, which is iOS-only). Native app used `.shared`, causing entitlement mismatch on upgrade. | Updated `native/macos/scripts/sign_app.sh` to grant strictly `$app_id` (`<TEAM_ID>.xyz.vidur.pux`) matching Flutter macOS release. Injected `PuxKeychainAccessGroup = $app_id` into `Info.plist`. All operations consistently use that group; no group-less fallback is attempted. | `KeychainStorageTests`, `RecordStoreTests.testFlutterKeychainUpgradeFixture` |
| **"Retry Now" Reconnect Lockout** | **P1** | User clicking "Retry now" during backoff called `start()`, but left `_isReconnecting = true`, permanently suppressing future reconnect attempts on subsequent network failures. | `start()` and `stopTasks()` explicitly reset `_isReconnecting = false` when replacing a session, ensuring subsequent disconnects can trigger reconnect cycles. | `DesktopDeliveryServiceTests.testRetryDuringBackoffFollowedByConnectionFailure` |
| **Non-Relocatable Vendored Libsodium & Stale Install Name** | **P1** | `libsodium.pc` had absolute worktree path; `libsodium.26.dylib` had Mach-O install name pointing to `/tmp/build-libsodium/...`. | Replaced `libsodium.pc` prefix with relative `${pcfiledir}/../..`. Changed dylib install name to `@rpath/libsodium.26.dylib` via `install_name_tool -id`. Deleted temporary build dirs. Added `-Xlinker -rpath` to build/test scripts. | `bundle_app.sh` rpath/dylib checks, `test.sh` execution |
| **Library Provenance & Compatibility Enforcement** | **P2** | Vendored libsodium lacked licensing and build provenance; architecture slices and deployment target were not validated in packaging. | Added `Vendor/libsodium/LICENSE` (ISC) and `PROVENANCE.md` (upstream `libsodium-1.0.22-stable`, SHA-256, build flags). `bundle_app.sh` strictly asserts fat slices (`x86_64` + `arm64`) and `minos <= 12.0`. | `bundle_app.sh` pre-bundle validation checks |
| **Held-Code Timer Recovery Before Network Startup** | **P2** | `start()` placed `ensureHoldTimerRunning()` after initial device registration, leaving preserved held codes unmonitored during offline retry loops. | Moved `ensureHoldTimerRunning()` to the very beginning of `DesktopDeliveryService.start()` prior to device registration or network poll. | `DesktopDeliveryServiceTests.testOfflineStartRestartsHoldTimerImmediately` |
| **Session Cancellation Realism in Tests** | **P2** | Previous cancellation test did not suspend presentation in-flight before calling `stop()`. | Enhanced `testDeliveryHandlingRespectsSessionCancellation` with an asynchronous presentation barrier, suspending presentation mid-flight, calling `stop()`, resuming presentation, and asserting post-presentation mutations are rejected. | `DesktopDeliveryServiceTests.testDeliveryHandlingRespectsSessionCancellation` |
| **Delivery Arrival During Poll Race** | **P1** | Deliveries held via WebSocket during an in-flight poll were purged when the poll completed with a partial page. | Snapshot `candidateIds = Set(_holding.keys)` *before* awaiting the network poll. Only items that were already candidate IDs when the poll began are evaluated for absence during partial-page cleanup. | `DesktopDeliveryServiceTests.testConcurrentDeliveryDuringPollNotDiscarded` |
| **Keychain Error UI Handling** | **P1** | Keychain read errors set `isEnrolled = false`, presenting the setup/import screen to users whose keys failed to read. | `DeliveryController` sets `storageError` and stops startup; `ContentView` renders a root `Keychain Storage Error` view with a retry action, blocking the setup flow and preventing accidental enrollment overwrite. | `RecordStoreTests.testInitializationKeychainErrorSetsStorageErrorAndDoesNotEnroll` |
| **Packaged Libsodium Deployment Target** | **P1** | Host Homebrew libsodium was built for macOS 26.0+, emitting linker warnings and risking incompatibility on macOS 12. | Built a universal fat binary (`x86_64` + `arm64`) of `libsodium-1.0.22` with `-mmacosx-version-min=12.0` in `Vendor/libsodium/`. `bundle_app.sh` bundles and verifies `minos 12.0`. Linker warnings eliminated. | Verified via `otool -l` and `lipo -info` during build and bundle. |
| **Offline Import Progress State** | **P2** | Modal import sheet awaited network registration, spinning indefinitely when offline. | `DeliveryController.commitEnrollment` saves keys locally, updates enrollment state, and initiates network startup asynchronously in the background. `ImportEnrollmentView` dismisses immediately to home. | `RecordStoreTests.testCommitEnrollmentSucceedsWithoutBlockingOnNetwork` |
| **Packaging Asset Compiler Failure Detection** | **P2** | `bundle_app.sh` suppressed `actool` output and ignored errors with `|| true`. | `bundle_app.sh` fails immediately if `actool` exits non-zero and verifies the existence of `AppIcon.icns` and `Assets.car` in the bundled Resources. | `bundle_app.sh` asset compilation verification |
| **Deletion Error Handling** | **P1** | Server deletion failures erased local enrollment, leaving orphaned relays. | Server errors propagate; local keys are preserved on failure. `DeleteRelayDialog` presents inline retryable errors. | `RecordStoreTests.testDeletionFailurePreservesLocalEnrollment`, `testRemoveDeviceFailurePreservesLocalEnrollment` |
| **Notification Code Retention** | **P1** | Plaintext OTP code persisted in `UNMutableNotificationContent.userInfo["code"]`. | Removed code from notification `userInfo`; stored strictly in-memory in `NotificationCodes` (15m expiry). | `NotificationCodesTests` (in-memory behavior only) |
| **Acknowledgement Retry Queue** | **P2** | Failed acks were not retried. | Added `_pendingAcks` queue retried on poll and reconnect without duplicating user notifications. | `DesktopDeliveryServiceTests.testFailedAckIsRetriedOnNextPollWithoutReshowing` |
| **Autonomous Acknowledgement Retry** | **P2** | After a presented delivery's DELETE failed, the delivery was no longer held, so the hold timer stopped and nothing scheduled a poll. The server could redeliver an already-presented code after a restart (retention is ten minutes). | `scheduleAckRetry()` runs a bounded, session-owned retry task while `_pendingAcks` is non-empty. Failures, polls and session start restart it; `stop()`, `clear()` and removal cancel it and a stale task cannot affect its successor. | `AckRetryTests` (automatic retry without a poll, backoff bounds, exhaustion then fresh series, stop and restart, clear, relay removal, late failure after stop, stale-session slot ownership, session takeover) |
| **Unlabeled Enrollment Editor** | **P3** | The import JSON `TextEditor` had nearby explanatory text but no accessibility label, so VoiceOver form navigation lacked a purpose-specific name. | `ImportEnrollmentView` labels the editor "Enrollment JSON" with a hint. | Source and compile verification only; not exercised with VoiceOver |
| **Full-Page Polling Purge** | **P2** | 50-item full page purged absent held codes. | Purge only executes on partial page (`< 50` items). | `DesktopDeliveryServiceTests.testFullPendingPageDoesNotPurgeAbsentHeldCodes` |

## Retrying an interrupted removal

A removal intent is stored locally before network work begins. Delivery stays paused across an app restart until the user retries the pending removal. Device removal first repeats registration with the stable desktop token to recover the server's device ID, saves that ID, then deletes it. Once deletion starts, retries repeat DELETE without registering again. Relay deletion similarly retries DELETE. If a response or local storage operation fails, enrollment is retained where possible and the app prompts for another retry.

If reconciliation receives the server's explicit `too_many_devices` rejection, the app retains the pending intent and offers two choices: free a device slot and retry, or explicitly forget the enrollment on this Mac only. The latter deletes local keys without verifying or claiming server removal; an earlier uncertain request may still be processed later. Local-only recovery is unavailable if a subsequent retry has an uncertain outcome.

This reconciliation relies on the server upsert returning the existing ID for a record and token. It handles a request that committed before its response was lost, but the current server API provides no deletion fence: an earlier timed-out registration that the server processes only after the reconciliation and DELETE could recreate the row. A server-side atomic token deletion or tombstone is needed to rule out that ordering. No live-server or signed Keychain verification of this flow has been performed.

## Release CI Integration Status

> [!IMPORTANT]
> Release CI builds the native macOS client.
>
> To transition CI to the native macOS build:
> 1. Run `./native/macos/scripts/bundle_app.sh release` (uses pre-bundled universal `Vendor/libsodium/`).
> 2. Codesign and notarize using `./native/macos/scripts/sign_app.sh native/macos/build/pux.app "$APPLE_SIGNING_IDENTITY" "$APPLE_TEAM_ID" "$PROVISIONING_PROFILE"`.
> 3. Zip `pux.app` for the release artifact upload.

## Precise Remaining Verification and Platform Blockers

The following areas are verified via automated unit tests and mock transports, but cannot be verified on physical hardware or live infrastructure in the current environment:

1. **Physical Keychain Migration Across Signatures (Hardware Blocker)**:
   - Reading Data Protection Keychain items written by the released Flutter desktop app requires that both applications share the identical Apple Team ID and `keychain-access-groups` entitlement (`<TEAM_ID>.xyz.vidur.pux`).
   - Without the official Apple Developer ID Application certificate and embedded provisioning profile (which reside as CI GitHub secrets and in the Apple Developer portal), macOS rejects Keychain operations with `errSecMissingEntitlement` (-34018), and headless execution may return `errSecNotAvailable` (-25291).
   - The in-memory fixture exercises the data format and key names; mocked Security queries exercise group selection and errors, but physical migration between installed signed app binaries remains **unverified** until signed with official credentials on physical hardware.
2. **macOS 12 (Monterey) Minimum-OS Execution (Hardware Blocker)**:
   - The application and bundled libraries target macOS 12.0 (`.macOS(.v12)` in `Package.swift`, `LSMinimumSystemVersion = 12.0` in `Info.plist`, and `Vendor/libsodium/` compiled with `-mmacosx-version-min=12.0`).
   - The packaging script checks the library deployment metadata for each architecture; API availability is guarded (`SMAppService` availability guards with deep-link fallback to System Preferences).
   - However, physical boot, launch, and execution on actual macOS 12 Monterey hardware has not been run on this macOS 15.3 host.
3. **Interactive GUI, VoiceOver & Visual Display Inspection (Display Blocker)**:
   - Automated tests cover selected controller and notification logic; they do not exercise SwiftUI dialogs or visual presentation.
   - However, in a headless CI/CLI environment without a live WindowServer display session (`CGSessionCopyCurrentDictionary()` returns `nil`), visual rendering, menu-bar popup positioning, dynamic Dark/Light mode theme switching, and VoiceOver accessibility tree navigation have not been interactively inspected.
4. **Live Server WebSocket Delivery (Network Blocker)**:
   - Network interactions are verified against local mock transports, wire contract unit tests, and offline fixtures.
   - Live socket delivery against an active, production-deployed server relay requires an online network host and is not verified in an offline sandbox.

## Release signing setup

### One-time setup

This reuses the `APPLE_TEAM_ID` variable and the App Store Connect API key from the [iOS setup](../ios/README.md#testflight-setup). Everything here is in the [Apple Developer portal](https://developer.apple.com/account) unless noted. Only the Account Holder can create Developer ID certificates.

1. **App ID.** `xyz.vidur.pux` is already registered for iOS, and Developer ID profiles use the same identifier. It needs no extra capabilities for macOS: keychain access groups need no capability.
2. **Developer ID certificate.** Make a signing request without touching Keychain:

   ```bash
   openssl req -new -newkey rsa:2048 -nodes -keyout developer_id.key -out developer_id.csr -subj "/CN=pux Developer ID"
   ```

   Under Certificates, add a **Developer ID Application** certificate (profile type **G2 Sub-CA**) from `developer_id.csr`, and download `developerID_application.cer`. Then bundle it with the key:

   ```bash
   openssl x509 -inform DER -in developerID_application.cer -out developer_id.pem
   # Homebrew OpenSSL 3 needs -legacy so macOS can import the file; LibreSSL's openssl doesn't accept it.
   openssl pkcs12 -export -legacy -inkey developer_id.key -in developer_id.pem -out developer_id.p12
   ```

3. **Provisioning profile.** Under Profiles, add a profile of type **Developer ID** (under Distribution), choose the App ID `xyz.vidur.pux` and the certificate from step 2, name it "pux Developer ID", and download it (`pux_Developer_ID.provisionprofile`). This profile is what lets the app use the keychain.
4. **API key.** Notarization uses the App Store Connect API key the TestFlight workflow already has (`APP_STORE_CONNECT_API_KEY`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`). Nothing to do unless those aren't set yet.
5. **Secrets.** From the directory holding the files:

   ```bash
   base64 -i developer_id.p12 | gh secret set MACOS_DEVELOPER_ID_CERT_P12_BASE64
   gh secret set MACOS_DEVELOPER_ID_CERT_PASSWORD          # the export password from step 2
   base64 -i pux_Developer_ID.provisionprofile | gh secret set MACOS_DEVELOPER_ID_PROFILE_BASE64
   ```

   Keep `developer_id.p12` and its password in a password manager, then delete the local copies.

6. **Try it.** Run the workflow by hand (`gh workflow run release.yml`), and open the disk image from the run's `macos` artifact on a Mac. The **Check keychain access** step proves the keychain works with this signature; if it fails with -34018, the profile and the entitlements don't match.

A release tag fails at the macOS job until these secrets are set, so nothing unsigned is published.

### Renewal

A Developer ID certificate lasts five years. Copies people already installed keep working after it expires, because the signature is timestamped, but new builds need a new certificate. Check the profile's expiry date in the portal too: an embedded profile that has expired can stop the app from launching, so ship a build with a fresh profile before then. To renew, repeat steps 2, 3 and 5.
