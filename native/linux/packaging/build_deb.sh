#!/usr/bin/env bash
# Packages the native Linux pux binary as a .deb for Debian and Ubuntu.
#
#   build_deb.sh <binary-path> <version> <output.deb>
#
# Installs to /opt/pux with a /usr/bin/pux link, desktop entry and icon.
# On Debian/Ubuntu uses dpkg-shlibdeps when available, or standard default dependencies.
set -euo pipefail

if [ $# -lt 3 ]; then
  echo "Usage: $0 <binary-path> <version> <output.deb>" >&2
  exit 64
fi

binary=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
version=${2/-/\~}
output=$3
here=$(cd "$(dirname "$0")" && pwd)

case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64) arch=arm64 ;;
  *) echo "error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root="$work/root"

install -d "$root/opt/pux" "$root/usr/bin" "$root/DEBIAN" \
  "$root/usr/share/applications" "$root/usr/share/icons/hicolor/512x512/apps" \
  "$root/usr/share/doc/pux"

install -m 755 "$binary" "$root/opt/pux/pux"
ln -s /opt/pux/pux "$root/usr/bin/pux"
install -m 644 "$here/xyz.vidur.pux.desktop" "$root/usr/share/applications/"
install -m 644 "$here/copyright" "$root/usr/share/doc/pux/copyright"

# Icon (required)
repo_root=$(cd "$here/../../.." && pwd)
icon_src="$repo_root/native/linux/packaging/assets/pux.png"
if [ ! -f "$icon_src" ]; then
  echo "error: icon missing at $icon_src" >&2
  exit 1
fi
install -m 644 "$icon_src" "$root/usr/share/icons/hicolor/512x512/apps/xyz.vidur.pux.png"

# Work out library dependencies
depends="libc6 (>= 2.35), libgtk-3-0 (>= 3.24.0), libglib2.0-0 (>= 2.70.0), libsecret-1-0 (>= 0.20.0), libcurl4, libssl3 (>= 3.0.0)"
if command -v dpkg-shlibdeps >/dev/null 2>&1; then
  mkdir -p "$work/debian"
  printf 'Source: pux\n\nPackage: pux\nArchitecture: any\n' > "$work/debian/control"
  if ! resolved=$(cd "$work" && dpkg-shlibdeps -O "$root/opt/pux/pux" 2>"$work/shlibdeps.log" | sed -n 's/^shlibs:Depends=//p'); then
    cat "$work/shlibdeps.log" >&2
    exit 1
  fi
  if [ -n "$resolved" ]; then
    depends="$resolved"
  fi
else
  echo "warning: dpkg-shlibdeps not available; using default Depends" >&2
fi

size=$(du -sk "$root" | cut -f1)
cat > "$root/DEBIAN/control" <<CONTROL
Package: pux
Version: $version
Architecture: $arch
Maintainer: Vidur Butalia <https://github.com/vidurb/pux>
Installed-Size: $size
Depends: $depends
Recommends: gnome-keyring | kwalletmanager | keepassxc
Section: utils
Priority: optional
Homepage: https://pux.vidur.xyz
Description: end-to-end encrypted bank OTP relay
 pux takes the OTP from the email your bank sends, end-to-end encrypts it and
 delivers it to your devices. This is the native Linux desktop client, which
 receives codes for a relay created on a phone.
 .
 Keys are stored in the Secret Service (GNOME Keyring, KWallet or KeePassXC).
CONTROL

find "$root" -type d -exec chmod 755 {} +
if command -v dpkg-deb >/dev/null 2>&1; then
  dpkg-deb --root-owner-group --build "$root" "$output"
  echo "Built $output"
else
  echo "dpkg-deb not available on this host; package tree staged at $root"
fi
