# Native clients and CI

The four clients live in `android/`, `ios/`, `macos/` and `linux/`. The
`native` workflow tests them on pull requests and produces trial artifacts.
The Android release artifacts use a disposable CI key and must not be
installed as upgrades or distributed. The macOS bundle is unsigned. Linux
packages are trial builds. The iOS job builds the simulator app and extension.
The `native` workflow does not publish a release.

The `release` and `testflight` workflows are wired to build the native clients.
Before using them for distribution, validate the actual signing identities,
Apple provisioning and production APNs entitlements, notarization, Firebase
configuration, and monotonically increasing store build numbers. The native
release paths have not been tested with production credentials. Existing
`github.run_number` values are scoped to each workflow; the run number in the
native trial workflow is not evidence of continuity with published builds.
Do not publish the trial artifacts as production releases.

The new workflow has not yet been exercised on GitHub-hosted runners. Tests
on a simulator or in a container do not verify live push delivery or the
behavior of a physical OS keychain, camera, notification service, or
accessibility tools. If no physical devices are available, these checks remain
unverified rather than being counted as passed.

A device registration request that times out can still arrive after removal
and recreate a server device row. An empty database removes existing rows but
does not fence future in-flight requests; a server ordering mechanism would be
needed to guarantee device removal.

Before the native rollout, exercise signed in-place upgrades from the released
clients on Android, iOS and macOS, including existing enrollment and device IDs,
protected storage, notification decryption, background delivery, removal and
recovery. Verify Linux migration against a real Secret Service keyring. Check
camera, clipboard, notification actions and accessibility on the target OSes.
Keep a rollback and re-enrollment plan, and do not treat fixture or simulator
tests as proof of hardware behavior.
