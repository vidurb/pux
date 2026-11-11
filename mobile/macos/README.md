# pux macOS

The macOS app is a desktop client: it imports an enrollment exported from a phone and receives codes over a WebSocket (see the root [README](../../README.md#mobile)). It doesn't use Firebase or APNs, and it doesn't use the camera.

## Entitlements

| Entitlement | Why |
|-------------|-----|
| `com.apple.security.app-sandbox` | The app runs sandboxed |
| `com.apple.security.network.client` | HTTPS and the delivery WebSocket |
| `keychain-access-groups`, `com.apple.application-identifier`, `com.apple.developer.team-identifier` | Release builds only, added at signing time (below) |

`Runner/Release.entitlements` holds the first two. Debug builds also get `allow-jit` and `network.server` (`Runner/DebugProfile.entitlements`), which Flutter needs for hot reload and the debugger.

### Keychain

`flutter_secure_storage` keeps the relay's keys in the **data protection keychain**. macOS only lets a program use it if its signature names a keychain access group. Without one, every write fails with `errSecMissingEntitlement` (-34018), so the app can't save an enrollment. That covers every ad-hoc build, including `flutter run` and `flutter build macos` without a team. On macOS the access-group entitlements are restricted, so they need a provisioning profile for the App ID embedded in the app. The release build embeds a Developer ID profile.

[`scripts/sign_app.sh`](scripts/sign_app.sh) re-signs the built app: it adds the keychain entitlements for `<TEAM_ID>.xyz.vidur.pux`, embeds the profile, and signs everything with the hardened runtime and a secure timestamp. [`scripts/keychain_probe.sh`](scripts/keychain_probe.sh) builds a tiny app with the same bundle ID, signs it the same way and writes a test item to the keychain. The release workflow runs it before notarizing.

To try a properly signed build on your own Mac, use the files from the setup below:

```bash
cd mobile
flutter build macos --release
macos/scripts/sign_app.sh build/macos/Build/Products/Release/pux.app \
  "Developer ID Application: <name> (<TEAM_ID>)" <TEAM_ID> pux_Developer_ID.provisionprofile
open build/macos/Build/Products/Release/pux.app
```

## Releases

The [`release`](../../.github/workflows/release.yml) workflow builds a universal (Apple silicon and Intel) app, signs it with a **Developer ID Application** certificate, notarizes and staples it, and ships it as `pux-<version>-macos.dmg`: a disk image holding the app and an Applications link, itself signed, notarized and stapled. Gatekeeper opens it without a warning, offline too.

The app is notarized on its own before it goes in the disk image, so its ticket is stapled to it and it still opens offline once copied to Applications.

Run the workflow by hand from the Actions tab (or `gh workflow run release.yml`) to try signing and notarization without a release; the disk image is attached to the run as the `macos` artifact.

### One-time setup

This reuses the `APPLE_TEAM_ID` variable and the App Store Connect API key from the [iOS setup](../ios/README.md#one-time-setup). Everything here is in the [Apple Developer portal](https://developer.apple.com/account) unless noted. Only the Account Holder can create Developer ID certificates.

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
