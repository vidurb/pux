# pux Linux Native Application

Experimental native Linux GTK 3 client for pux, targeting compatibility with the Flutter desktop client and server.

## Overview & Architecture

The application is structured into modular C++ components designed for Linux desktop environments:

```
native/linux/
├── CMakeLists.txt              # Build configuration for core library, app, and tests
├── README.md                   # Architecture, build, test, and parity documentation
├── packaging/
│   ├── xyz.vidur.pux.desktop   # Freedesktop application entry
│   ├── build_deb.sh            # Debian/Ubuntu .deb packaging script
│   ├── build_tar.sh            # Release tarball: binary plus README.txt
│   ├── check_tar.sh            # Tarball layout, guidance and linked-library check
│   ├── tarball-README.txt      # Runtime dependency guidance shipped in the tarball
│   ├── runtime-libs.txt        # Libraries the binary may link, and how users get them
│   ├── test_packaging.sh       # Regression tests for the tarball packaging (CTest)
│   └── copyright               # License attribution
├── src/
│   ├── crypto/                 # Libsodium sealed boxes & unpadded base64url
│   │   ├── crypto.hpp
│   │   └── crypto.cpp
│   ├── storage/                # Secret Service & RecordStore
│   │   ├── secret_store.hpp
│   │   ├── secret_store.cpp
│   │   ├── record_store.hpp
│   │   └── record_store.cpp
│   ├── api/                    # HTTP client (/api/v1, /health) with Bearer auth
│   │   ├── api_client.hpp
│   │   └── api_client.cpp
│   ├── notifications/          # D-Bus org.freedesktop.Notifications & in-memory codes
│   │   ├── notification_service.hpp
│   │   └── notification_service.cpp
│   ├── clipboard/              # Sensitive clipboard with 60s auto-clear
│   │   ├── sensitive_clipboard.hpp
│   │   └── sensitive_clipboard.cpp
│   ├── delivery/               # Desktop delivery state machine, poll, hold, expiry
│   │   ├── desktop_delivery_service.hpp
│   │   └── desktop_delivery_service.cpp
│   ├── ui/                     # GTK 3 native window and dialogs
│   │   ├── app_window.hpp
│   │   └── app_window.cpp
│   ├── vendor/                 # Single-header JSON parser (nlohmann/json)
│   │   └── json.hpp
│   └── main.cpp                # GTK application entry point
└── tests/                      # Automated unit test suite (listed in CMakeLists.txt)
    ├── test_harness.hpp        # Lightweight assertion framework
    ├── test_main.cpp           # Test runner
    ├── test_crypto.cpp         # Libsodium & server fixture verification
    ├── test_record_store.cpp   # QR parsing, validation & atomic rollback
    ├── test_notifications.cpp  # Payload parsing & URL whitelist validation
    ├── test_api_client.cpp     # REST client endpoints & error mapping
    ├── test_delivery_service.cpp # Delivery state machine & holding logic
    ├── test_secret_service.cpp # Secret Service schema compatibility
    └── test_sensitive_clipboard.cpp # 60s clipboard clear logic
```

## Runtime & Build Dependencies

### Build Dependencies
- CMake 3.16+
- C++17 compiler (GCC 11+ or Clang 14+)
- `pkg-config`
- `libgtk-3-dev` (GTK+ 3.24+)
- `libglib2.0-dev` (GLib / GIO 2.70+)
- `libsodium-dev` (libsodium 1.0.18+)
- `libcurl4-openssl-dev` (cURL 7.80+; OpenSSL TLS backend)
- `libssl-dev` (OpenSSL 3.x; linked explicitly for libcurl TLS symbols)
- `libsecret-1-dev` (libsecret 0.20+)
- `openssl` CLI (runtime check for the Linux ALPN integration test; usually from the `openssl` package)

Linux builds link libsodium statically by default and need its static archive.
Install `libsodium-dev` on Debian/Ubuntu or `libsodium-devel` and
`libsodium-static` on Fedora. For a source build using the system shared
library instead, configure CMake with `-DPUX_STATIC_SODIUM=OFF`; that build
requires a compatible libsodium at runtime and cannot be packaged as the
portable release tarball.

### Runtime Dependencies
- `libgtk-3-0`
- `libglib2.0-0`
- `libsecret-1-0`
- `libcurl4`
- `libssl3` (OpenSSL 3)
- A Secret Service provider (`gnome-keyring`, `kwalletmanager`, or `keepassxc`) running on the session D-Bus.
- A notification daemon (`org.freedesktop.Notifications` on D-Bus) for desktop alerts.

## Building & Testing

### Build the Application and Tests
```bash
cd native/linux
mkdir -p build && cd build
cmake ..
make -j$(nproc)
```

### Run Unit Tests
```bash
./pux_linux_tests
```
or with CTest:
```bash
ctest --output-on-failure
```

**Linux-only test extras** (no extra `-dev` packages beyond the build deps above):
- `websocket_tls_connect_disables_h2_alpn_selection` needs the **`openssl` CLI** (`s_server` / `s_client`) on `PATH`. It does **not** compile against `libssl-dev` headers.
- Keyring integration tests need an unlocked session Secret Service; use `PUX_REQUIRE_KEYRING=1 ./pux_linux_tests` in CI to treat skips as failures.

### Run the Application
```bash
./pux
```

### Packaging (.deb and release tarball)
```bash
../packaging/build_deb.sh ./pux <version> pux-<version>-linux-amd64.deb
../packaging/build_tar.sh ./pux <version> pux-<version>-linux-x64.tar.gz
```

The release workflow builds this native client and packages it with `build_tar.sh` and `build_deb.sh`. The updated job still needs verification on a GitHub-hosted Ubuntu runner before release.

The tarball contains `pux` and a `README.txt` (from `tarball-README.txt`). Linux builds link libsodium statically and use system libraries for the remaining dependencies, so that README is how a user on another distribution learns what to install: GTK 3, libsecret, libcurl and OpenSSL 3, with the `apt`, `dnf` (Fedora) and `pacman` (Arch) commands. `build_tar.sh` runs `check_tar.sh` on the result. For an ELF binary it reads the linked libraries with `readelf` and fails the build if one is missing from `runtime-libs.txt`, or if a library marked `documented` there (for example `libcurl.so.4`) is not named in the README. A change of library version on the build machine therefore forces the guidance to be updated instead of shipping out of date.

The tarball links the library versions of the Ubuntu 22.04 build machine. A distribution that ships a different major version of one of them (for example, OpenSSL with another soname) cannot satisfy it by installing the package; `ldd ./pux | grep "not found"` shows this, and the README points to the `.deb` or a source build.

```bash
packaging/test_packaging.sh   # layout, guidance, drift against the top-level README; ELF checks on Linux
```

## Security & Storage Compatibility

### 1. Secret Service Compatibility (Flutter Migration)
The existing Flutter Linux client used `flutter_secure_storage_linux` (v3.0.3) backed by libsecret:
- **Schema Attribute:** `account` = `xyz.vidur.pux.secureStorage`
- **Item Label:** `xyz.vidur.pux/FlutterSecureStorage`
- **Payload:** JSON object (`record_id`, keys, `server_url`, etc.)

Flutter 3.0.3 can store items whose `xdg:schema` name is **corrupted** (SSO bug in `Secret.hpp`): after `setLabel()`, the schema name in the keyring may not be `"default"`. The native client looks up legacy items with `SECRET_SCHEMA_DONT_MATCH_NAME` (attributes only), validates enrollment shape strictly, migrates into a normal item, verifies the read-back, then clears the legacy item. Writes are refused while the keyring is locked, unavailable, corrupt, or while an unmigrated legacy item remains.

- **Verified in unit tests:** attribute names, FSS JSON filters, corrupt JSON detection, memory enrollment reads.
- **Linux + session keyring integration tests** (`#if HAVE_LIBSECRET`): migration, clear/reopen (`{}`), preference-only + legacy migration, corrupt native, enrollment conflict, retry. Without a keyring they emit `[ SKIPPED ]` (not silent pass). For mandatory CI on Ubuntu with GNOME Keyring: `PUX_REQUIRE_KEYRING=1 ./build/pux_linux_tests` (skipped keyring tests count as failed; fixture seed/clear failures throw).
- **Unverified:** cutover on a real upgraded user keyring database (GNOME Keyring / KWallet).

### 2. Strict Keyring Requirement (No Plaintext File Fallback)
- Like the Flutter Linux client, pux strictly requires an unlocked Secret Service provider (`gnome-keyring`, `kwalletmanager`, or `keepassxc`) on the D-Bus session bus.
- There is **no unencrypted file fallback**: storing private keys in plain files (regardless of POSIX permissions) does not preserve secure-storage semantics.
- If `org.freedesktop.secrets` is missing or has no owner on the session bus, `SecretServiceStore` fails safely with `KeyringUnavailableException`:
  `"Secret Service provider (GNOME Keyring, KWallet or KeePassXC) is not running on the session bus. pux requires an active Secret Service to store private keys securely."`
- If the default keyring is locked, operations throw `KeyringLockedException` and the UI shows a recovery screen (Retry), not the setup/import flow.
- Corrupt JSON or failed legacy migration throws `KeyringCorruptException` / `LegacyEnrollmentPendingException` with the same recovery UI; writes never run on a failed read.
- If storage write fails during enrollment, all partially written keys are removed and `record_id` is only written last, preventing corrupt or half-enrolled states.

### 3. Plaintext Codes in Memory Only
- Plaintext OTP codes and decrypted payloads are stored strictly in memory (`NotificationCodes`, `holding_`, `recent_`).
- Codes expire after 15 minutes and are removed from the app's active caches; the app does not guarantee memory zeroization.
- Plaintext codes are never written to disk, caches, or logs.

### 4. D-Bus Notifications & Failure Behavior
- The app sends notifications to `org.freedesktop.Notifications.Notify` over the session D-Bus with action `copy_code` ("Copy code").
- If the notification daemon is missing, locked, or times out (10s), the code is held in memory in the `held` list without being acknowledged to the server. The code appears in the UI ("Codes that may not have appeared") with a Copy button so the user can still access their OTP.
- The 30-second recheck loop retries displaying held codes and only acknowledges them to the server once successfully delivered to an active daemon.
- Recent codes are kept in memory for 15 minutes on Linux because the desktop environment does not report whether a notification was physically seen before being dismissed.

### 5. Sensitive Clipboard Handling
- Secrets copied to clipboard (OTP codes or exported enrollment JSON) use `SensitiveClipboard`.
- The clipboard is **not** stored in the clipboard manager (`gtk_clipboard_store` is not used), matching Flutter.
- A 60-second timer checks whether the clipboard still contains the exact secret string. If unchanged, it clears the clipboard. External clipboard edits are preserved.

### 6. Confirmation URL Allowlisting
- Email forwarding confirmation links received in `forward_confirm` notifications are restricted strictly to Google domains:
  - `mail.google.com`
  - `mail-settings.google.com`
- Links must use `https://`, have no port, and contain no credentials/userinfo. Any other URL is rejected and not opened.

## Verification & Parity Assessment

The native Linux GTK client is under development. It is not yet verified as a replacement for the Flutter Linux client.

| Component | Status | Verification & Evidence | Limitations / Unverified Areas |
| :--- | :--- | :--- | :--- |
| **Libsodium Sealed-Box Cryptography** | Verified | Tested against server test fixtures and PR fixtures with Curve25519 / unpadded base64url. | Cryptographic primitive parity verified; full end-to-end server live session requires network integration testing. |
| **Key Generation & Encoding** | Verified | Unit tests confirm 32-byte key generation, base64url without padding, and roundtrip encryption/decryption. | None. |
| **Enrollment QR / JSON Validation** | Verified | Strict V1 JSON schema validation: UUID, 32-byte keys, valid scheme, rejection of credentials/userinfo. | None. |
| **Secret Service Storage (libsecret)** | Verified against Fixtures | Matches `flutter_secure_storage_linux-3.0.3` schema (`default`), account attribute, and item label. Keyring operations run on a serialized worker; GTK reads a memory snapshot after successful operations. No plaintext fallback on disk. | Live migration and loading/error views against a real keyring remain unverified. |
| **REST API Client** | Verified | Implements cURL HTTP client for `/api/v1` and `/health`, Bearer authentication, and typed exceptions for 401/404, 422, 429, 409. | None. |
| **Live WebSocket Delivery & Polling** | In progress | The client uses libcurl connect-only transport and a pinned wslay snapshot. Local socket tests exercise handshake and framing, service reconnect after peer close, and elapsed fallback polling. | Ubuntu 22.04 build, TLS and live Phoenix delivery remain unverified. |
| **Device-limit Recovery** | Implemented & Tested | A `422 too_many_devices` registration rejection shows the device-limit banner and schedules a registration retry (30 s, doubling to 10 min), so a slot freed on another device is picked up without a restart. The banner also has a **Retry registration** button that registers immediately and restarts the backoff. Retries stop on `suspend()`/`stop()` (removal, keyring failure), never overlap an in-flight registration, and leave the visible state alone until they succeed. Portable service tests cover freeing a slot, the manual retry and the removal gate. | The banner test and its focus handling need a GTK display (`xvfb-run` in CI) and were not run on the host this was written on. |
| **Held & Recent Code Recovery** | Verified with Tests | Tested against failure-then-recovery scenario: held code successfully displayed on retry transfers to `recent` and acks to server. Expired codes update UI even when holding queue is empty. Reconnect preserves in-memory codes. | None. |
| **D-Bus Notifications & Actions** | Implemented & Tested | Sends `Notify` over session D-Bus, captures daemon-assigned uint32 ID, subscribes to `ActionInvoked` ("copy_code" / "default") and `NotificationClosed`. In-memory code cache (15m expiry). | Tested with mock notifications and unit tests; real desktop notification daemons (GNOME Shell, Dunst, Mako) interaction unverified on this host (no Xvfb/display). |
| **Sensitive Clipboard Auto-Clear** | Verified | 60-second timer clears secret if clipboard text remains unchanged, preserves external clipboard edits. Headless display safety checked. | None. |
| **Confirmation URL Allowlist** | Verified | Strict allowlist restricted to `mail.google.com` and `mail-settings.google.com` over HTTPS with no port or credentials. | None. |
| **Destructive Actions Error Handling** | Implemented | A keyring intent is persisted before remote removal; startup retries pending removal before delivery starts. Recovery offers a warned local-only removal, which does not claim the server operation succeeded. | The GTK dialog and real keyring recovery have not been exercised on a Linux desktop. |
| **GTK 3 User Interface & Accessibility** | Implemented | Setup screen with a text view named "Enrollment JSON" for assistive technology (ATK name, described by the instructions above it) and error label, active relay view with inbox address and health check, visual Cairo QR code generator (using Nayuki's QR generator), status banner, copy buttons with ATK accessible names and tooltips. Keyring Retry restarts delivery. Object lifetime tokens prevent dangling pointer callbacks. | **Visual UI unverified on real desktop:** host environment lacks Linux display/Wayland session; theme integration, font scaling, and screen readers require physical testing. |
| **Linux Tarball** | Script and guidance tested | `build_tar.sh` ships `README.txt` with Debian/Ubuntu, Fedora and Arch install commands for GTK 3, libsecret, libcurl and OpenSSL 3; `check_tar.sh` fails the build on a missing README, missing or mismatched commands, or an ELF binary that links a library the guidance does not cover. `test_packaging.sh` passed on macOS and, including its ELF cases, in a Debian 12 container. | The real Ubuntu-built tarball has not been run on a clean Fedora or Arch image. Those distributions may ship library versions with different sonames than this build links (see above). |
| **Debian Packaging (.deb)** | Script Updated | `build_deb.sh` packages binary into `/opt/pux` with desktop entry and icon, requiring `libsecret-1-0 (>= 0.20.0)`. | Physical package install and uninstall on Debian/Ubuntu machines unverified. |

If the keyring cannot confirm the initial removal intent, no remote removal is attempted. The app keeps the request in memory and remains running when its window closes, allowing retry, verified cancellation, or warned local-only removal. A forced process exit while the intent is unconfirmed can lose that in-memory request.

## Explicit Remaining Limitations

1. **Host Environment Display Absence:** This build and verification environment is macOS without an active Linux desktop session (X11/Wayland), D-Bus session bus with `org.freedesktop.Notifications`, or Secret Service provider.
2. **Visual Inspection Gap:** Native UI layout, high-DPI text scaling, dark/light theme switching, and AT-SPI assistive technology behavior were inspected by code structure, not measured visually on a live Linux display.
3. **Live Keyring Provider Integration:** While schema compatibility and upgrade fixtures pass, cutover against an existing user's GNOME Keyring database on disk should be verified in a real Linux staging environment prior to final release.
4. **Physical Debian Package Testing:** The `.deb` package generation script was updated with all runtime dependencies (`libsecret-1-0`), but has not been installed on a live Ubuntu or Debian system.
