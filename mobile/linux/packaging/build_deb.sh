#!/usr/bin/env bash
# Packages a `flutter build linux --release` bundle as a .deb for Debian and Ubuntu.
#
#   build_deb.sh <bundle-dir> <version> <output.deb>
#
# The bundle goes to /opt/pux with a /usr/bin/pux link, a desktop entry and an
# icon. Library dependencies come from dpkg-shlibdeps, so run this on the oldest
# distribution the package should install on (the release workflow uses Ubuntu
# 22.04). Needs dpkg-dev.
set -euo pipefail

if [ $# -ne 3 ]; then
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
fi

bundle=$(cd "$1" && pwd)
# Debian sorts "~" before anything, so a pre-release such as 0.2.0-rc.1 becomes
# 0.2.0~rc.1 and upgrades cleanly to 0.2.0.
version=${2/-/\~}
output=$3
here=$(cd "$(dirname "$0")" && pwd)
icon="$here/../../assets/icon/macos.png"

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
cp -a "$bundle/." "$root/opt/pux/"
ln -s /opt/pux/pux "$root/usr/bin/pux"
install -m 644 "$here/xyz.vidur.pux.desktop" "$root/usr/share/applications/"
# The icon source is 1024px; hicolor has no such size, so declare it as 512 and
# let the icon theme scale it.
install -m 644 "$icon" "$root/usr/share/icons/hicolor/512x512/apps/xyz.vidur.pux.png"
install -m 644 "$here/copyright" "$root/usr/share/doc/pux/copyright"

# dpkg-shlibdeps wants a debian/control; the libraries in the bundle are private,
# so tell it where they are and let it resolve only the system ones.
mkdir -p "$work/debian"
printf 'Source: pux\n\nPackage: pux\nArchitecture: any\n' > "$work/debian/control"
mapfile -t elves < <(find "$root/opt/pux" -type f \( -name pux -o -name '*.so*' \) -print)
depends=$(cd "$work" && dpkg-shlibdeps -O -l"$root/opt/pux/lib" "${elves[@]}" 2>"$work/shlibdeps.log" \
  | sed -n 's/^shlibs:Depends=//p') || { cat "$work/shlibdeps.log" >&2; exit 1; }
test -n "$depends" || { echo "error: dpkg-shlibdeps found no dependencies" >&2; cat "$work/shlibdeps.log" >&2; exit 1; }

size=$(du -sk "$root" | cut -f1)
cat > "$root/DEBIAN/control" <<CONTROL
Package: pux
Version: $version
Architecture: $arch
Maintainer: vidurb <https://github.com/vidurb/pux>
Installed-Size: $size
Depends: $depends
Recommends: gnome-keyring | kwalletmanager | keepassxc
Section: utils
Priority: optional
Homepage: https://pux.vidur.xyz
Description: end-to-end encrypted bank OTP relay
 pux takes the OTP from the email your bank sends, end-to-end encrypts it and
 delivers it to your devices. This is the desktop app, which receives codes
 for a relay created on a phone.
 .
 Keys are kept in the Secret Service (GNOME Keyring, KWallet or KeePassXC),
 so one must be running in the desktop session.
CONTROL

find "$root" -type d -exec chmod 755 {} +
dpkg-deb --root-owner-group --build "$root" "$output"
dpkg-deb --info "$output"
