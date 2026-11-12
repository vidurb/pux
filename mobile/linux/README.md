# pux Linux

The Linux app is a desktop client like the macOS one: it imports an enrollment exported from a phone and receives codes over a WebSocket. Install instructions for users are in the root [README](../../README.md#installing-the-desktop-apps).

## Runtime dependencies

| Needs | Used for |
|-------|----------|
| glibc 2.35 or later | The release is built on Ubuntu 22.04 |
| GTK 3 (`libgtk-3-0`) | The Flutter embedder |
| EGL and OpenGL ES (`libegl1`, `libgles2`, from Mesa or a GPU driver) | Rendering. The engine loads them at run time, so `dpkg-shlibdeps` can't find them and the `.deb` lists them by hand |
| libsecret (`libsecret-1-0`) | `flutter_secure_storage` keeps the relay's keys through it |
| A Secret Service provider, running and unlocked: GNOME Keyring, KWallet or KeePassXC | Where libsecret actually stores the keys. Without one, the app fails at startup with `org.freedesktop.secrets was not provided by any .service files` |
| A notification daemon (`org.freedesktop.Notifications` on D-Bus) | Showing codes. Every desktop environment has one |

libsodium and the Flutter engine are bundled in `lib/`. The app doesn't use the camera on desktop.

## Packaging

The [`release`](../../.github/workflows/release.yml) workflow builds the bundle on Ubuntu 22.04 (x86-64) and ships it two ways:

- `pux-<version>-linux-amd64.deb`, made by [`packaging/build_deb.sh`](packaging/build_deb.sh). It installs the bundle to `/opt/pux`, links `/usr/bin/pux`, and adds a desktop entry (`xyz.vidur.pux.desktop`, matching the GTK application ID) and an icon. `dpkg-shlibdeps` works out the library dependencies, so building on the oldest supported release keeps the package installable there. It recommends a keyring.
- `pux-<version>-linux-x64.tar.gz`, the bare bundle, for other distributions.

The bundle carries the icon as `data/xyz.vidur.pux.png` (from `assets/icon/macos.png`), and the app sets it on its window, so the tarball shows it too. Wayland compositors ignore window icons and look up the desktop entry instead, so there the tarball has none unless you add an entry yourself; the `.deb`'s entry covers it. `build_deb.sh` takes the icon theme's copy from the bundle.

To build the package locally on Debian or Ubuntu (needs `dpkg-dev`):

```bash
cd mobile
flutter build linux --release
linux/packaging/build_deb.sh build/linux/x64/release/bundle 0.0.0 pux.deb
```

Not built yet, and worth adding if people ask: Flatpak (Flathub needs an offline build of Flutter from source, and the sandbox needs the Secret Service and notification portals), AppImage (one file for every distribution, but needs FUSE 2, which recent Ubuntu doesn't install, and still depends on the host's keyring), RPM, and arm64 builds.
