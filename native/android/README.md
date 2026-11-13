# pux - Native Android Application

Pure native Android client for **pux**, providing encrypted OTP relay notifications forwarded from bank emails.

Built with Modern Android, Jetpack Compose, Material 3, Android Keystore, CameraX, ML Kit, and Kotlin Coroutines/Flow. Completely standalone and isolated in `native/android/`.

---

## 1. Architecture Overview

This Kotlin Android client implements the existing server protocol and enrollment format. Fixture tests cover interoperability; a production Flutter upgrade and live push delivery still require device verification.

```
native/android/app/src/main/kotlin/xyz/vidur/pux/
├── PuxApplication.kt               # Application setup, Keystore init, migration trigger
├── MainActivity.kt                 # Compose navigation host, clipboard focus hooks
├── api/
│   └── ApiClient.kt                # OkHttp REST client for pux server (/api/v1)
├── crypto/
│   └── PuxCrypto.kt                # Libsodium-compatible sealed box crypto (X25519 + XSalsa20-Poly1305 + Blake2b)
├── model/
│   └── Models.kt                   # RelayNotification, TestCode, ServerHealth, DeliveryStatus
├── push/
│   ├── PuxFirebaseMessagingService.kt  # FCM data message receiver and decryptor
│   ├── NotificationHelper.kt       # High-importance notifications with lock-screen privacy
│   ├── CopyCodeActivity.kt         # Translucent activity for "Copy code" notification action (foreground copy)
│   └── SensitiveClipboard.kt       # Sensitive clipboard manager (EXTRA_IS_SENSITIVE + 60s clear + focus gate)
├── service/
│   └── DeliveryController.kt       # Push registration state machine, 12h refresh, backoff + jitter
├── storage/
│   ├── RecordStore.kt              # Keystore-backed EncryptedSharedPreferences with atomic writes
│   └── FlutterSecureStorageMigrator.kt # v11 Flutter storage migrator with safe non-destructive fallback
├── system/
│   ├── BackgroundRestrictions.kt   # Hibernation (API 31) and battery restriction detector
│   └── NotificationPermissions.kt  # Android 13+ POST_NOTIFICATIONS permission manager
└── ui/
    ├── QrCodeUtil.kt               # ZXing QR code generator for "Add device" display
    ├── components/                 # ServerStatusCard, DeliveryBanner, DeliveryPromptsBanner
    ├── dialogs/                    # ConfirmServerDialog, DeleteRelayDialog, RemoveDeviceDialog, SentTestCodeDialog
    ├── screens/                    # HomeScreen, EnrollChooserScreen, CreateRelayScreen, EnrollScreen, ImportEnrollmentScreen, ForwardingHelpScreen
    └── theme/                      # pux brand color palette (#0E3B32, emerald, teal) and Material 3 theme
```

---

## 2. Security & Privacy Guarantees

- **Wire-Compatible Libsodium Sealed Box Cryptography:**
  - Implements Curve25519 (`X25519`) key exchange, `hsalsa20` core, `XSalsa20Engine` stream cipher, `Poly1305` authenticator, and `Blake2bDigest` (24-byte nonce calculation from ephemeral public key and recipient public key).
  - Matches the Elixir server's `:enacl.box_seal` and libsodium's `crypto_box_seal` / `crypto_box_seal_open`.
  - Pure Java/Kotlin via BouncyCastle without requiring brittle native JNI `.so` libraries.
- **Hardware-Backed Keystore Storage:**
  - Relay credentials, server URL, public key, private key, and device ID are stored in `EncryptedSharedPreferences` backed by the Android Keystore (`AES256_GCM` + `AES256_SIV`).
  - **Atomic write order:** writes `inbox`, `server_url`, `public_key`, `private_key`, and finally `record_id`. If any key fails to write, partial keys are rolled back immediately.
- **Backup & Cloud Extraction Protection:**
  - `backup_rules.xml` and `data_extraction_rules.xml` explicitly exclude `shared_prefs` and `databases` from Google Drive cloud backups, device transfers, and ADB backups.
- **Lock-Screen Privacy:**
  - The `pux_otp` notification channel enforces `NotificationCompat.VISIBILITY_PRIVATE`. OTP codes and forwarding confirmation links remain concealed on the lock screen until the device is unlocked.
- **Sensitive Clipboard Management:**
  - Copied OTPs and exported enrollment JSON payloads are flagged with `ClipDescription.EXTRA_IS_SENSITIVE` (Android 13+) and `"android.content.extra.IS_SENSITIVE"` (Android 7+), suppressing clipboard history previews and floating chip overlays.
  - A 60-second timer may schedule clearing; **clearing is not automatic in the background**. `SensitiveClipboard` starts with no window focus; Activities must call `onWindowFocusChanged` from their lifecycle. Clear attempts are skipped until focus is true (`SensitiveClipboardTest`).
  - Notification "Copy code" uses [CopyCodeActivity](app/src/main/kotlin/xyz/vidur/pux/push/CopyCodeActivity.kt). Copy and notification dismissal happen only after the activity window reports focus—never in `onCreate`. If clipboard read fails (e.g. denied while unfocused), the pending clear schedule stays until a later focused attempt succeeds.
- **No Secrets in URLs:**
  - The relay record ID is treated as a sensitive credential and is strictly transmitted in the `Authorization: Bearer <record_id>` header.
- **Server URL Validation:**
  - Enforces HTTPS for all remote servers, requiring scheme and host while rejecting user info, query parameters, and URL paths.
  - Plain HTTP is permitted strictly for local development on `localhost`, `127.0.0.1`, and Android emulator host alias `10.0.2.2`.

---

## 3. Flutter Secure Storage Migration (v11)

The app inspects and migrates existing Flutter storage upon startup:
- Flutter Secure Storage v11 on Android stores the wrapped AES key in shared preferences file `FlutterSecureKeyStorage` (with legacy fallback to `FlutterSecureStorage`) under key `AESVGhpcyBpcyB0aGUga2V5IGZvciBhIHNlY3VyZSBzdG9yYWdlIEFFUyBLZXkK`.
- The wrapping key in Android Keystore uses alias `${context.packageName}.FlutterSecureStoragePluginKeyOAEP` with RSA/ECB/OAEPWithSHA-256AndMGF1Padding.
- Encrypted data entries live in `FlutterSecureStorage` with key prefix `VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIHNlY3VyZSBzdG9yYWdlCg_`. Data values consist of a 12-byte IV prepended to AES/GCM/NoPadding ciphertext with a 128-bit authentication tag.
- Migrates `record_id`, `private_key`, `public_key`, `inbox`, `server_url`, `device_id`, and `notification_permission_asked`.
- **Safe Fallback:** If the Keystore key cannot be unwrapped (e.g. key invalidated, different application signing key, or missing Keystore entry), the migrator fails safely: it logs the condition, preserves existing data untouched, and allows the user to re-enroll or import their relay JSON without data loss.

---

## 4. UI & Features

1. **Enroll Chooser Screen:** Initial view when not enrolled, offering "Create new relay" and "Add to existing relay". Fully scrollable for compact screens.
2. **Create Relay Screen:** Generates a fresh 32-byte Curve25519 keypair, calls `POST /api/v1/records` with the public key, saves credentials atomically, and transitions to the Home Screen. Scrollable with responsive spacing.
3. **Enroll Screen (QR Scanner):** Live CameraX viewfinder with Google ML Kit Barcode Scanning. Automatically validates and prompts confirmation before saving. Includes a direct "Paste enrollment JSON instead" button.
4. **Import Enrollment Screen:** Full-featured text field for pasting exported enrollment JSON, with payload validation, server confirmation, scroll support, and `rememberSaveable` state retention.
5. **Home Screen:**
   - **Delivery Prompts Banner:** Proactively surfaces notification access issues (`NOT_ASKED`, `CHANNEL_OFF`, `QUIET`, `DENIED`), app hibernation (`API_31`), battery restrictions, or quiet channels, with direct "Open settings" and "Dismiss" buttons. Re-evaluates instantly on `ON_RESUME`.
   - **Server Status Card:** Live reachability indicator checking `GET /health` with host display and tap-to-recheck. Automatically kicks retrying delivery if server becomes reachable.
   - **Delivery Banner:** Visual status indicator for `CONNECTING`, `RETRYING` (with backoff countdown and "Retry now"), `RECORD_UNKNOWN` (with "Forget relay"), and `TOO_MANY_DEVICES`.
   - **Inbox Address Card:** Selectable inbox address, one-tap clipboard copy, "How to set up forwarding" navigation, and "Send a test code" button.
   - **Add Another Device (QR View):** Toggles display of enrollment QR code (rendered via ZXing) and "Copy enrollment JSON" button with security warning dialog.
   - **Overflow Actions:** "Remove this device" (calls `DELETE /devices/{id}`) and "Delete relay everywhere" (calls `DELETE /records/{id}` with mandatory `"delete"` confirmation typing). Includes functional retry on network failure and state restoration on cancellation.
6. **Forwarding Help Screen:** Comprehensive forwarding guides for Gmail, Outlook.com, and other providers, with known bank OTP email sender details (HSBC, RBL Bank) and test instructions.
7. **Fail-Closed Keystore Protection:** If Android Keystore initialization fails, displays a non-dismissible `KeystoreErrorDialog` that exits the app, preventing unencrypted secret storage.
8. **Predictable Navigation:** Navigation backstack is preserved across configuration changes and process recreations via `rememberSaveable`, wired to the system `BackHandler`.

---

## 5. Build and Test

### Prerequisites
- JDK 17 (e.g. `temurin-17` via `mise`)
- Android SDK (API 34/35/36/37)

### Run Unit Tests
```bash
cd native/android
./gradlew test
```
Unit tests cover libsodium sealed-box cryptography, API client error mapping and threading, Keystore atomic writes, Flutter storage v11 migration, delivery backoff/jitter, and notification parsing.

### Build Debug APK
```bash
cd native/android
./gradlew assembleDebug
```
The output APK is generated at `app/build/outputs/apk/debug/app-debug.apk`.

### Release Signing & Versioning
Release builds configure signing using `key.properties` (or `-PkeyProperties=/path/to/key.properties`) and accept `-PversionCode` (or `-PbuildNumber`) and `-PversionName` command-line overrides:
```bash
cd native/android
./gradlew assembleRelease -PkeyProperties=key.properties -PversionCode=10 -PversionName=0.2.0
```
A template is available at `native/android/key.properties.example`. Release packaging requires `key.properties`; it fails when signing configuration is absent. Relative `storeFile` paths are resolved from the properties file directory.

**Release blocker (CI wiring):** Native release APKs/AABs must pass the workflow run number as `-PversionCode` (Flutter uses `github.run_number` in `.github/workflows/release.yml`). Release builds fail if `versionCode` is omitted (debug may default to `1`).

**Default server URL:** Override at build time with `-PpuxServerUrl=https://…` (BuildConfig `DEFAULT_SERVER_URL`, default `https://pux.vidur.xyz`, same as Flutter’s `PUX_SERVER_URL` default). Enrollment still trusts the server URL stored at enroll time.

### Flutter upgrade verification
- **Fixture migration:** `FlutterSecureStorageMigratorFixtureTest` encrypts values in the v11 AES-GCM layout and migrates all `RecordStore` keys with an injectable `AesKeyUnwrapper` (Keystore unwrap is not exercised in unit tests).
- **Still required before release:** A signed in-place upgrade on a disposable device with real Flutter v11 secure-storage data (RSA-OAEP unwrap via Android Keystore) and live push delivery.

### Clipboard (platform limitations)
Copy always runs in the foreground (`CopyCodeActivity`, Home, forwarding help). Enrollment, inbox, and OTP copies use `SensitiveClipboard` (sensitive flag). A 60s clear timer may fire in the background, but **clearing only runs after the main window regains focus** (`MainActivity` → `onWindowFocusChanged`; see `SensitiveClipboardTest`). Clearing is **best-effort** and **not guaranteed** on every device:

| Limitation | Behavior |
| :--- | :--- |
| Background access (Android 10+) | Apps cannot read or clear the clipboard while unfocused; the 60s timer defers clear until the next window focus (`SensitiveClipboardTest`). |
| Vendor / OEM behavior | Some devices ignore `EXTRA_IS_SENSITIVE` or alter clipboard history; pux cannot force OS-level hiding everywhere. |
| User override | If the user copies something else before clear runs, pux leaves the foreign clip untouched. |
| Notification copy | `CopyCodeActivity` finishes immediately after copy; auto-clear still depends on focus as above. |

This is an **unavoidable platform constraint**, not a pux bug.

### Terra review (`thr_ys5t4waw5f`) — six findings
| # | Finding | Resolution | Tests |
| :--- | :--- | :--- | :--- |
| 1 | H2 stale-registration warning dropped | Durable `RemovalNoticeStore` + chooser dialog; uncertain registration at removal | `RemovalNoticeStoreTest`, `RemovalControllerNoticeTest` |
| 2 | Migration Continue orphans Flutter data | Block setup until retry/discard; partial keys fail closed; reconcile matches record+keys; retry does not resume delivery with pending removal | `FlutterSecureStorageMigratorTest`, `FlutterSecureStorageMigratorFixtureTest`, `PuxApplicationMigrationRetryTest` |
| 3 | Scanner Cancel left camera paused | `CameraBinding.unpauseForRebind()` on dialog dismiss | `CameraBindingTest` |
| 4 | Deletion cancel stuck delivery / pending intent | DNS/unreachable DELETE clears pending on cancel; in-flight keeps intent; FORGET cancel never drops pending | `RemovalControllerDnsCancelTest`, `RemovalControllerCancelTest` |
| 5 | Clipboard clear in background | Document limits; focus-gated clear | `SensitiveClipboardTest` |
| 6 | Contrast / localization | Banners use `puxSemantic` / `colorScheme`; clipboard strings in `strings.xml` | `ThemeContrastTest`, `DeliveryBannerScreenTest`, `DeliveryPromptsBannerScreenTest` |

### Dependencies
`androidx.security:security-crypto:1.1.0-alpha06` remains for `EncryptedSharedPreferences` parity with the migration path; replacing it needs an offline-compatible alternative that does not break Flutter storage migration.

---

## 6. Audit Remediation & Parity Notes

Following independent reviews (thread `thr_ys5t4waw5f`), the following actionable findings were addressed and verified with regression tests:

| Finding | Classification | Resolution |
| :--- | :--- | :--- |
| **Launcher Activity Name** | P0 Bug | Changed manifest launcher activity from `.ui.MainActivity` to `.MainActivity`. Verified merged manifest. |
| **UI Thread Networking** | P1 Quality | Converted all `ApiClient` network methods to Kotlin `suspend` functions explicitly executed on `Dispatchers.IO`. Injected `ioDispatcher` for testability. |
| **Flutter Storage v11 Compatibility** | P1 Compatibility | Updated migrator to inspect `FlutterSecureKeyStorage`, use Keystore alias `<package>.FlutterSecureStoragePluginKeyOAEP` with RSA-OAEP, and decrypt AES-GCM data in `FlutterSecureStorage`. |
| **Enrollment Resurrection** | P1 Lifecycle | Added durable migration tombstone in `pux_migration_state` and removed legacy enrollment entries while retaining unrelated secure-storage entries and the shared wrapping key, upon migration and local forget/removal in `RecordStore.clear(context)`. Verified with unit tests. |
| **FCM Registration & False Ready** | P1 Delivery | Removed silent fallback to `FirebaseInstallations.id` on register failure or timeout. Propagate errors into exponential backoff retries (`DeliveryState.RETRYING`); `READY` is set strictly after confirmed FCM and server registration. Verified with unit tests. |
| **Cancellation & Concurrency Races** | P1 Concurrency | Guarded controller lifecycle with `isStarted`, incremented `currentGeneration` on start/stop to discard stale asynchronous responses, serialized server device registrations with `Mutex.withLock`, and preserved `CancellationException` propagation so `stop()` never schedules retries or resurrects registrations. Verified with unit tests. |
| **Keystore Fail-Closed** | P1 Security | Removed silent unencrypted SharedPreferences fallback. If Keystore cannot be initialized, app presents a non-dismissible exit dialog. |
| **Resume & Prompt Staleness** | P2 Lifecycle | `MainActivity` and `DeliveryPromptsBanner` register lifecycle observers on `Lifecycle.Event.ON_RESUME` to recheck permissions, battery/hibernation state, and the 12-hour delivery heartbeat. |
| **Backstack & State Restoration** | P2 Navigation | Navigation backstack converted to `rememberSaveable` using `listSaver` and wired to system `BackHandler`. Input text in `ImportEnrollmentScreen` uses `rememberSaveable`. |
| **Removal Retry / Cancellation** | P2 UX | Fixed `HomeScreen` removal failure dialogs: RETRY now executes deletion immediately, and CANCEL restores `removing = false` and restarts delivery. |
| **Release Packaging & Overrides** | P2 Build | Configured `signingConfigs.release` reading `key.properties` with support for CLI version injection (`versionCode` / `versionName`), verified v2 signing scheme via `apksigner`. |
| **Camera Cleanup & Error Fallback** | P2 Camera | Managed `cameraExecutor` and `barcodeScanner` lifetimes with `DisposableEffect(Unit)` (closing on view disposal). Added error state catching bind failures, presenting an actionable warning card with a direct "Paste enrollment JSON instead" button. |
| **Adaptive Layouts** | P2 UI | Added `verticalScroll` and flexible height constraints to `EnrollChooserScreen`, `CreateRelayScreen`, and `ImportEnrollmentScreen` to support small screens and large fonts. |

### Real-Device & Signed-Upgrade Limitations

- **Physical Device Protection:** Connected physical device `0A111FDD4002P2` has the production Flutter client (`package:xyz.vidur.pux`) installed with live user credentials. Overwriting via `adb install` was strictly omitted to prevent signature mismatch (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`) and secret erasure. Visual on-device testing was not performed on this device.
- **Signed In-Place Upgrade Requirements:** Upgrading an installed production Flutter build in-place on a user device requires:
  1. Signing the native release APK with the identical release keystore (configured via `native/android/key.properties` matching `mobile/android/key.properties`).
  2. Setting a `versionCode` strictly greater than the currently installed Flutter client (passed via `-PversionCode=<int>` or `-PbuildNumber=<int>`).
  An incompatible signing key prevents an upgrade; an insufficient version code is also rejected. The production upgrade has not been tested.
- **Live Push Interoperability Boundary:** Verified through unit test mocks and FID registration state machines. End-to-end receipt of live incoming FCM pushes from the production server requires an active enrolled device connected to Google Play Services.
