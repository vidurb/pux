# libsodium Universal Binary Provenance and Build Recipe

This directory contains pre-compiled universal (`arm64` and `x86_64`) `libsodium` dynamic libraries built for macOS 12.0+ deployment.

## Source Upstream & Verification

- **Bundled dylib** (`lib/libsodium.26.dylib`)
- **Binary SHA-256**: `d9b752d7445af252240defbcbe86c667822a2cf2efb9ec993924fab97b8219b3`
- **Version**: 1.0.22-stable
- **Source Archive**: `libsodium-1.0.22-stable.tar.gz`
- **Official Minisign Signature**: `libsodium-1.0.22-stable.tar.gz.minisig`
- **Source Checksum (SHA-256)**:
  `b55ff300455d61ffc610931215b67272cc33575b630e20173543ef6ff7989d97`

## Build Recipe

Built using Apple Clang targeting macOS 12.0 Monterey deployment baseline:

### 1. Apple Silicon (arm64)
```bash
./configure \
  --prefix=/path/to/arm64/dist \
  CFLAGS="-O3 -mmacosx-version-min=12.0" \
  --disable-dependency-tracking
make -j8 && make install
```

### 2. Intel (x86_64)
```bash
./configure \
  --host=x86_64-apple-darwin \
  --prefix=/path/to/x86_64/dist \
  CC="clang -arch x86_64" \
  CFLAGS="-O3 -arch x86_64 -mmacosx-version-min=12.0" \
  --disable-dependency-tracking
make -j8 && make install
```

### 3. Universal Fat Binary Creation
```bash
lipo -create \
  /path/to/arm64/dist/lib/libsodium.26.dylib \
  /path/to/x86_64/dist/lib/libsodium.26.dylib \
  -output lib/libsodium.26.dylib

install_name_tool -id "@rpath/libsodium.26.dylib" lib/libsodium.26.dylib
codesign -f -s - lib/libsodium.26.dylib
ln -sf libsodium.26.dylib lib/libsodium.dylib
```

## Relocatable Pkg-Config
`lib/pkgconfig/libsodium.pc` uses `prefix=${pcfiledir}/../..` to ensure full relocatability across different repository checkouts and CI environments.
