#!/usr/bin/env bash
# Regression tests for the Linux tarball packaging (build_tar.sh, check_tar.sh,
# tarball-README.txt, runtime-libs.txt). Needs only bash, tar and a C compiler;
# the ELF cases run on Linux with a compiler and readelf and are skipped
# elsewhere (set PUX_REQUIRE_PACKAGING_ELF=1 to make a skip a failure).
#
#   native/linux/packaging/test_packaging.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/pux-package.XXXXXX")
trap 'rm -rf "$work"' EXIT

passed=0
failed=0
skipped=0

pass() { passed=$((passed + 1)); echo "[ OK ] $1"; }
fail() { failed=$((failed + 1)); echo "[FAIL] $1" >&2; }
skip() { skipped=$((skipped + 1)); echo "[SKIP] $1"; }

# expect_fail <name> <message fragment> <command...>
expect_fail() {
  local name=$1 fragment=$2 out status=0
  shift 2
  out=$("$@" 2>&1) || status=$?
  if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -qF -- "$fragment"; then
    pass "$name"
  else
    fail "$name (status $status; wanted '$fragment'; got: $out)"
  fi
}

# expect_ok <name> <command...>
expect_ok() {
  local name=$1 out status=0
  shift
  out=$("$@" 2>&1) || status=$?
  if [ "$status" -eq 0 ]; then pass "$name"; else fail "$name (status $status: $out)"; fi
}

# Package names after "<prefix> ", sorted, one per line.
packages_after() { # <file> <prefix>
  grep -F -- "$2" "$1" | head -n 1 | sed -e "s/.*$2 //" -e 's/[`|].*//' | tr ' ' '\n' | grep -v '^$' | sort
}

fake_binary="$work/pux-fake"
printf '#!/bin/sh\nexit 0\n' > "$fake_binary"
chmod 755 "$fake_binary"

# --- layout -----------------------------------------------------------------
tarball="$work/pux-0.0.0-linux-x64.tar.gz"
expect_ok "build_tar.sh packages a binary with its README" "$here/build_tar.sh" "$fake_binary" 0.0.0 "$tarball"
listing=$(tar -tvzf "$tarball" 2>&1 || true)
if printf '%s\n' "$listing" | grep -E -- '-rwxr-xr-x.* \./pux$' >/dev/null; then pass "tarball has an executable ./pux at the root"; else fail "tarball has an executable ./pux at the root: $listing"; fi
if printf '%s\n' "$listing" | grep -E -- '-rw-r--r--.* \./README\.txt$' >/dev/null; then pass "tarball has ./README.txt at the root"; else fail "tarball has ./README.txt at the root: $listing"; fi
if printf '%s\n' "$listing" | grep -E -- '-rw-r--r--.* \./copyright$' >/dev/null; then pass "tarball includes license notices"; else fail "tarball is missing license notices: $listing"; fi
expect_ok "check_tar.sh accepts the packaged tarball" "$here/check_tar.sh" "$tarball"

# --- guidance content -------------------------------------------------------
readme="$here/tarball-README.txt"
for word in "GTK 3" libsecret libsodium libcurl OpenSSL "Secret Service" Fedora Arch "not found"; do
  if grep -qiF -- "$word" "$readme"; then pass "README.txt mentions $word"; else fail "README.txt mentions $word"; fi
done

# The commands in the tarball README and the top-level README must not drift apart.
top="$repo/README.md"
if [ -f "$top" ]; then
  for pair in "Fedora|sudo dnf install" "Arch|sudo pacman -S"; do
    label=${pair%%|*}
    prefix=${pair#*|}
    in_tar=$(packages_after "$readme" "$prefix")
    in_top=$(packages_after "$top" "$prefix")
    if [ -n "$in_tar" ] && [ "$in_tar" = "$in_top" ]; then
      pass "$label packages match between README.md and the tarball README"
    else
      fail "$label packages differ: tarball README [$(printf '%s ' "$in_tar")] vs README.md [$(printf '%s ' "$in_top")]"
    fi
  done
else
  skip "top-level README.md not found; skipped the drift check"
fi

# Every library CMake requires has a runtime-libs.txt entry that is documented.
cmake_file="$here/../CMakeLists.txt"
for pair in "gtk+-3.0|libgtk-3.so.0" "glib-2.0|libglib-2.0.so.0" "libsecret-1|libsecret-1.so.0" \
            "CURL|libcurl.so.4" "OpenSSL|libssl.so.3" "OpenSSL|libcrypto.so.3"; do
  cmake_name=${pair%%|*}
  soname=${pair#*|}
  if ! grep -qF -- "$cmake_name" "$cmake_file"; then
    fail "CMakeLists.txt no longer references $cmake_name; update this test and runtime-libs.txt"
  elif grep -E -- "^$(printf '%s' "$soname" | sed 's/[.*+]/\\&/g')[[:space:]]+system[[:space:]]+documented" "$here/runtime-libs.txt" >/dev/null; then
    pass "runtime-libs.txt documents $soname for $cmake_name"
  else
    fail "runtime-libs.txt does not list $soname as system/documented ($cmake_name)"
  fi
done

# --- negative layout cases --------------------------------------------------
# rebuild <name> <mutator>: unpack the good tarball, run the mutator in the tree, repack.
rebuild() {
  local name=$1 dir="$work/mut-$1"
  mkdir "$dir"
  tar -xzf "$tarball" -C "$dir"
  ( cd "$dir" && "$2" )
  tar -C "$dir" -czf "$work/$name.tar.gz" .
}
drop_readme() { rm README.txt; }
drop_copyright() { rm copyright; }
drop_pux() { rm pux; }
sed_dnf_only() { sed -i.bak -e '/sudo dnf install/s/ libcurl//' README.txt && rm -f README.txt.bak; }
no_pacman() { sed -i.bak '/sudo pacman -S/d' README.txt && rm -f README.txt.bak; }
unexec_pux() { chmod 644 pux; }

rebuild no-readme drop_readme
expect_fail "check_tar.sh rejects a tarball without README.txt" "README.txt" "$here/check_tar.sh" "$work/no-readme.tar.gz"
rebuild no-copyright drop_copyright
expect_fail "check_tar.sh rejects a tarball without license notices" "copyright" "$here/check_tar.sh" "$work/no-copyright.tar.gz"
rebuild no-pux drop_pux
expect_fail "check_tar.sh rejects a tarball without pux" "pux is missing" "$here/check_tar.sh" "$work/no-pux.tar.gz"
rebuild unexec unexec_pux
expect_fail "check_tar.sh rejects a non-executable pux" "not executable" "$here/check_tar.sh" "$work/unexec.tar.gz"
rebuild no-fedora-curl sed_dnf_only
expect_fail "check_tar.sh rejects a Fedora command without libcurl" "Fedora command is missing libcurl" "$here/check_tar.sh" "$work/no-fedora-curl.tar.gz"
rebuild no-arch no_pacman
expect_fail "check_tar.sh rejects a README without an Arch command" "Arch install command" "$here/check_tar.sh" "$work/no-arch.tar.gz"

# --- ELF cases (Linux only) -------------------------------------------------
elf_ok=0
if [ "$(uname -s)" = Linux ] && command -v readelf >/dev/null 2>&1 && { command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1; }; then
  elf_ok=1
fi
if [ "$elf_ok" = 1 ]; then
  cc_bin=$(command -v cc || command -v gcc)
  stubs="$work/stubs"
  mkdir "$stubs"
  printf 'int stub_symbol(void) { return 1; }\n' > "$stubs/stub.c"
  printf 'int stub_symbol(void);\nint main(void) { return stub_symbol() ? 0 : 1; }\n' > "$stubs/main.c"

  # make_elf <output> <soname of the library it links>
  make_elf() {
    local out=$1 soname=$2
    "$cc_bin" -shared -fPIC -Wl,-soname,"$soname" -o "$stubs/$soname" "$stubs/stub.c"
    "$cc_bin" -o "$out" "$stubs/main.c" "-L$stubs" "-l:$soname"
  }

  make_elf "$work/pux-elf-ok" libcurl.so.4
  expect_ok "an ELF linking documented libraries packages cleanly" \
    "$here/build_tar.sh" "$work/pux-elf-ok" 0.0.0 "$work/elf-ok.tar.gz"

  make_elf "$work/pux-elf-newsodium" libsodium.so.23
  expect_fail "a dynamically linked libsodium fails the build" \
    "release builds must link libsodium statically" "$here/build_tar.sh" "$work/pux-elf-newsodium" 0.0.0 "$work/elf-newsodium.tar.gz"

  make_elf "$work/pux-elf-unknown" libundocumented.so.1
  expect_fail "an undocumented library fails the build" \
    "libundocumented.so.1, which is not in runtime-libs.txt" "$here/build_tar.sh" "$work/pux-elf-unknown" 0.0.0 "$work/elf-unknown.tar.gz"
else
  msg="ELF checks need Linux, readelf and a C compiler"
  if [ -n "${PUX_REQUIRE_PACKAGING_ELF:-}" ]; then fail "$msg"; else skip "$msg"; fi
fi

echo "========================================"
echo "Passed:  $passed"
echo "Skipped: $skipped"
echo "Failed:  $failed"
[ "$failed" -eq 0 ]
