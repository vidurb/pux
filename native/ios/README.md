# pux iOS Native Client

Native iOS client and Notification Service Extension for **pux**, under development. Parity with the Flutter client and end-to-end push delivery have not been established.

---

## Architecture & Directory Structure

```
native/ios/
├── Package.swift                    # Swift Package definition (PuxCore, PuxApp, NotificationService)
├── Pux.xcodeproj/                   # Xcode project with shared scheme 'Pux'
│   └── xcshareddata/xcschemes/Pux.xcscheme
├── Sources/
│   ├── PuxCore/                     # Shared core logic & models (macOS & iOS compatible)
│   │   ├── Extensions/              # Base64URL, UUID validation, etc.
│   │   ├── Models/                  # EnrollmentPayload, RelayNotification, DeliveryStatus, etc.
│   │   └── Services/                # CryptoService, ApiClient, RecordStore, PuxKeychain, DeliveryController
│   ├── PuxApp/                      # SwiftUI Application
│   │   ├── Assets.xcassets/         # App icons & AccentColor (Pine & Mint brand colors)
│   │   ├── Info.plist               # App metadata, camera usage description
│   │   ├── Pux.entitlements         # Keychain access group & push notifications
│   │   ├── PuxApp.swift             # @main SwiftUI App entry point
│   │   ├── PuxTheme.swift           # Color palette (Pine, Mint, Paper, Ink, etc.)
│   │   └── Views/                   # Screen & component views (Home, Enroll, QRScanner, etc.)
│   └── NotificationService/         # iOS Notification Service Extension
│       ├── Info.plist               # Extension point definition
│       ├── NotificationService.entitlements # Shared Keychain access group
│       └── NotificationService.swift # Intercepts APNs alerts, decrypts sealed boxes
├── Tests/
│   └── PuxCoreTests/                # unit tests
│       ├── ApiClientTests.swift
│       ├── CryptoServiceTests.swift
│       ├── DeliveryControllerTests.swift
│       ├── FcmRegistrationTests.swift
│       ├── KeychainMigrationTests.swift
│       ├── MockURLProtocol.swift
│       ├── RecordStoreTests.swift
│       ├── RecordStoreKeychainIsolationTests.swift  # spy backend: injected storage never reaches the global Keychain
│       ├── AppBootstrapTests.swift                  # launch-context detection and gated launch steps
│       ├── PuxKeychainDefaultBackendTests.swift
│       ├── EnrollmentImportAccessibilityTests.swift
│       ├── SpyPuxKeychainBackend.swift
│       └── RelayNotificationTests.swift
├── scripts/
│   └── generate_xcodeproj.py        # Python generator for Pux.xcodeproj
```

---

## Keychain Sharing & Migration

The app is architected for shared access between the main app and background extension:

- **Service Name**: `flutter_secure_storage_service`
- **Access Group**: `$(AppIdentifierPrefix)xyz.vidur.pux.shared`
- **Accessibility**: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- **Keys Preserved**:
  - `record_id`: UUID of the registered relay record.
  - `public_key`: Base64URL-encoded Curve25519 public key.
  - `secret_key`: Base64URL-encoded Curve25519 secret key.
  - `device_id`: Device identifier registered with the server.
  - `server_url`: Base URL of the pux server (defaults to `https://pux.vidur.xyz`).
  - `notification_permission_asked`: Boolean tracking whether the permission explainer was shown.

### Legacy Item Migration & Full Erasure
- On first launch, `PuxKeychain.migrateLegacyItems()` scans for existing un-grouped keychain items created by earlier Flutter versions and copies them into the shared access group so the Notification Service Extension can read them even when the app is terminated.
- When forgetting or resetting a relay, `PuxKeychain.delete()` and `deleteAll()` purge items from **both** the shared access group and un-grouped legacy storage, ensuring no orphan keys remain.
- Keychain deletion errors are strictly propagated by `RecordStore` rather than silently swallowed.

---

## Notification Service Extension (Background Decryption)

When an encrypted APNs push notification arrives, iOS invokes `NotificationServiceExtension`:

1. Extracts the Base64URL-encoded ciphertext from `userInfo["ciphertext"]` or a nested `userInfo["data"]["ciphertext"]` dictionary.
2. Retrieves the relay secret key from the shared Keychain access group.
3. Decrypts the libsodium anonymous sealed box (`crypto_box_seal_open`).
4. Formats the notification banner:
   - **OTP Codes**: Shows title `"OTP from <sender>"` and the code as the body; an explicitly unverified sender is marked.
   - **Forwarding Confirmations**: Surfaces confirmation URLs from allowlisted domains (`mail.google.com`, `mail-settings.google.com`), sets the notification category to `FORWARDING_CONFIRMATION`, and attaches `confirmation_url` to `userInfo`. When tapped, `AppDelegate` validates the URL domain and opens it directly in Safari.

---

## Push Delivery & FCM Registration

1. **Firebase Configuration**: Reads `GoogleService-Info.plist` dynamically.
2. **FCM Registration**: The Firebase Messaging SDK associates the APNs token and supplies an FCM registration token. The app registers and refreshes that token with the pux server.
3. **Delivery Controller Status**: If Firebase configuration is missing or invalid, `DeliveryController` transitions to `.firebaseUnconfigured` with clear user-facing diagnostics instead of reporting fake readiness.
4. **Lifecycle Resumption**: On scene phase transition to `.active`, `DeliveryController.onResume()` checks connectivity and reconnects if idle/failed.

---

## UI Accessibility & Adaptive Contrast

- **Adaptive Colors**: Defined via dynamic `UIColor(traitCollection:)` in `PuxTheme`, ensuring high-contrast visibility across both light and dark modes (avoiding low-contrast dark controls on dark backgrounds).
- **Enrollment JSON editor**: `ImportEnrollmentScreen`'s text editor is named "Enrollment JSON" for VoiceOver (`EnrollmentImportAccessibility`), with a hint and a UI-test identifier.
- **Camera Failure & Simulator Recovery**: `QRScannerView` inspects `AVCaptureDevice.authorizationStatus(for: .video)`. If denied or restricted, it surfaces an actionable recovery banner linking directly to iOS Settings. On simulators where a camera is unavailable, it guides users to manual JSON/code import.
- **Dynamic Type & Small Screens**: Setup screens (`EnrollChooserScreen`, `CreateRelayScreen`, `ImportEnrollmentScreen`, `NotificationExplainerView`) are wrapped in `ScrollView` with responsive padding.

---

## Building and Testing

### Running Unit Tests via Swift PM
```bash
cd native/ios
swift test --disable-sandbox
```
*(The `--disable-sandbox` argument prevents nested sandbox restrictions when executing tests within restricted or agent environments).*

The core tests cover:
- Cryptographic sealed-box interoperability with official Elixir server fixtures and typed PR fixtures.
- Strict QR code format validation (UUID syntax, required fields, version checks, insecure HTTP rejection).
- ApiClient HTTP responses, error mappings (401/404 RecordNotFound, 409 NoDevices, 422 TooManyDevices, 429 RateLimited), and `/health` checks.
- Notification formatting, DKIM unverified sender markers, and URL allowlist enforcement.
- DeliveryController exponential backoff, jitter calculations, and error state transitions.
- Keychain fallback, legacy migration, and deletion using in-memory test doubles.
- Firebase configuration validation and registration error handling.
- Test isolation (below): a spy backend proves an injected store never reaches the global Keychain, and a spy launch sequence proves hosted tests skip the production launch work.

### Test isolation: no real Keychain, APNs or Firebase

- `RecordStore` derives storage availability only from the `KeyValueStore` it was given. `KeychainKeyValueStore` still reads through `PuxKeychain`, so production behaviour is unchanged; an in-memory store no longer consults the process-wide backend.
- `PuxLaunchContext.current` is `.test` in any XCTest process, including the host app of app-hosted tests (it checks the XCTest environment variables, which exist before the test bundle loads). In `.test`, `PuxKeychain.backend` starts as `InMemoryPuxKeychainBackend` and `RecordStore.shared` uses in-memory storage and journals, so nothing reaches Security by default. Tests that swap the backend must restore the previous one, never `LivePuxKeychainBackend()`.
- `AppDelegate` runs Keychain migration, the protected-data observer, notification-center wiring, APNs registration and Firebase configuration only through `AppBootstrap.run`, which runs none of them in `.test`. Production order is unchanged.
- The `PuxTests` Xcode target is hosted by `Pux.app`, so it launches the real `AppDelegate`; the gate above is what keeps that launch off the production services. The gate is unit-tested with spy steps; the `AppDelegate` wiring itself was compiled but not run in a simulator.

### Xcode Project & Command-line Builds
Generate or update the standalone Xcode project at any time:
```bash
python3 native/ios/scripts/generate_xcodeproj.py
```
To build the app and extension with `xcodebuild`:
```bash
xcodebuild -project native/ios/Pux.xcodeproj -scheme Pux -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```
To build test targets:
```bash
xcodebuild -project native/ios/Pux.xcodeproj -scheme Pux -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build-for-testing
```

---

## Precise Remaining Limitations

1. **APNs Device Signing**: Physical device push notification receipt requires an active Apple Developer Program team ID and provisioning profiles with the `aps-environment` entitlement and Keychain Sharing group `$(AppIdentifierPrefix)xyz.vidur.pux.shared`.
2. **Live Firebase FCM End-to-End**: Registration against live Google endpoints requires network connectivity and a valid bundle ID registered in the Firebase console matching `GoogleService-Info.plist` with APNs authentication keys uploaded.
3. **Physical Device VoiceOver & Haptics**: While semantic labels and accessibility traits are defined, physical device VoiceOver traversal and Dynamic Type XXL scaling on actual iPhone hardware should be inspected before App Store submission.

## Release versioning (CI blocker)

`scripts/generate_xcodeproj.py` reads `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` / `BUILD_NUMBER` from the environment (defaults: pubspec marketing version and `1`). **Before App Store / TestFlight**, regenerate the Xcode project or pass the same settings to `xcodebuild`:

- `MARKETING_VERSION` — user-facing semver (release-please / `mobile/pubspec.yaml`).
- `CURRENT_PROJECT_VERSION` — monotonic build number (Flutter iOS uses `github.run_number` from `.github/workflows/testflight.yml`; wire the native `ios` job the same way when it ships).

Debug builds use `Sources/PuxApp/Pux.entitlements` (`aps-environment` = development); Release uses `PuxRelease.entitlements` (production). The Notification Service Extension keeps its own entitlements file.

Firebase iOS SDK is pinned to **13.1.1** with `FirebaseMessagingInstallationIdEnabled` in Info.plist (FID registration, matching Flutter).

Signing, archive, real Keychain migration, notification taps, and physical-device delivery still require end-to-end validation.

Pending FCM registration tokens are kept in the Keychain until the server-assigned device ID is saved. Removal retries an uncertain registration before deleting the resulting ID; if reconciliation fails, the user can retry or explicitly forget locally. For installations created before this tracking existed, a missing device ID cannot be recovered this way. A timed-out request might also still be executing on the server after reconciliation and deletion; eliminating that race requires server-side coordination.

An interrupted removal is recorded in a separate Keychain journal before server deletion. On restart, delivery stays paused and the app offers retry, local forgetting, or an explicit return to delivery. Local cleanup retains the journal until credential deletion completes; an unreadable journal also blocks delivery. These recovery paths have unit coverage with in-memory storage and still need signed-device Keychain verification.

`DELETE` for devices and relays treats HTTP 401 and 404 as success (already gone), matching the Flutter client and server record-auth behaviour.

An ad-hoc signed simulator build or archive does not establish device provisioning. Physical-device signing requires an Apple Developer team, appropriate app and extension provisioning profiles, Push Notifications and Keychain Sharing entitlements, and Firebase APNs configuration. Device archive, installation and live push delivery require separate verification.
