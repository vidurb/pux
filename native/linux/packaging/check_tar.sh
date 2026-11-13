#!/usr/bin/env bash
# Verify a pux Linux tarball: layout, dependency guidance and, for an ELF
# binary, that every library it links is a baseline library or one the README
# tells the user to install.
#
#   check_tar.sh <pux-x.y.z-linux-x64.tar.gz>
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <tarball>" >&2
  exit 64
fi

here=$(cd "$(dirname "$0")" && pwd)
tarball=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")

fail() { echo "check_tar: $*" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/pux-package.XXXXXX")
trap 'rm -rf "$work"' EXIT
tar -xzf "$tarball" -C "$work" || fail "cannot extract $tarball"

[ -f "$work/pux" ] && [ -x "$work/pux" ] || fail "pux is missing or not executable at the tarball root"
[ -s "$work/README.txt" ] || fail "README.txt (runtime dependency guidance) is missing or empty"
[ -s "$work/copyright" ] || fail "copyright (license notices) is missing or empty"
grep -qF 'Frank Denis' "$work/copyright" || fail "copyright is missing the libsodium ISC notice"
readme="$work/README.txt"

# The guidance must name every required library and give each distribution an
# install command that lists the packages providing them.
for word in "GTK 3" libsecret libsodium libcurl OpenSSL; do
  grep -qiF -- "$word" "$readme" || fail "README.txt does not mention $word"
done
require_command() { # <label> <command prefix> <package>...
  local label=$1 prefix=$2 line pkg
  shift 2
  line=$(grep -F -- "$prefix" "$readme" | head -n 1 || true)
  [ -n "$line" ] || fail "README.txt has no $label install command ($prefix ...)"
  for pkg in "$@"; do
    case " $line " in *" $pkg "*) ;; *) fail "README.txt $label command is missing $pkg: $line" ;; esac
  done
}
require_command "Debian/Ubuntu" "sudo apt install" libgtk-3-0 libsecret-1-0 libcurl4 libssl3
require_command "Fedora" "sudo dnf install" gtk3 libsecret libcurl openssl-libs
require_command "Arch" "sudo pacman -S" gtk3 libsecret curl openssl

if [ "$(head -c 4 "$work/pux" | od -An -tx1 | tr -d ' \n')" != 7f454c46 ]; then
  echo "check_tar: pux is not an ELF binary; skipped the library checks"
  exit 0
fi

command -v readelf >/dev/null 2>&1 || fail "readelf is required to check an ELF binary"
needed=$(readelf -d "$work/pux" | sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\]/\1/p')

for soname in $needed; do
  case "$soname" in
    libsodium.so*) fail "pux links $soname dynamically; release builds must link libsodium statically" ;;
  esac
  class=
  documented=-
  while read -r pattern pclass pdoc _; do
    case "$pattern" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2254  # the pattern is a glob on purpose
    case "$soname" in $pattern) class=$pclass; documented=${pdoc:--}; break ;; esac
  done < "$here/runtime-libs.txt"
  case "$class" in
    baseline|system) ;;
    *) fail "pux links $soname, which is not in runtime-libs.txt; add it there and to the install guidance" ;;
  esac
  if [ "$documented" = documented ]; then
    grep -qF -- "$soname" "$readme" ||
      fail "pux links $soname but README.txt does not name it; update tarball-README.txt for this build"
  fi
done
echo "check_tar: $(basename "$tarball") ok"
