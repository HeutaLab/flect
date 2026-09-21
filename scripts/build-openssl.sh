#!/usr/bin/env bash
# Builds OpenSSL's libcrypto as a static, universal library (Apple silicon
# and Intel) that runs on macOS 14 and later, into build/openssl.
# Package.swift links it in preference to Homebrew's, which only suits the
# Mac it was installed on.
#
# Usage: scripts/build-openssl.sh
set -euo pipefail

VERSION=3.5.8  # long-term support until April 2030
SHA256=a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2
MIN_MACOS=14.0

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$ROOT/build/openssl"
# OpenSSL's makefiles can't cope with spaces in paths, so build elsewhere.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Fetching OpenSSL $VERSION"
curl -fsSL -o "$WORK/openssl.tar.gz" \
  "https://github.com/openssl/openssl/releases/download/openssl-$VERSION/openssl-$VERSION.tar.gz"
echo "$SHA256  $WORK/openssl.tar.gz" | shasum -a 256 -c - >/dev/null

for ARCH in arm64 x86_64; do
  echo "Building libcrypto for $ARCH"
  mkdir -p "$WORK/src-$ARCH"
  tar -xzf "$WORK/openssl.tar.gz" -C "$WORK/src-$ARCH" --strip-components 1
  (
    cd "$WORK/src-$ARCH"
    LOG="$WORK/build-$ARCH.log"
    {
      ./Configure "darwin64-$ARCH-cc" no-shared no-tests \
        "-mmacosx-version-min=$MIN_MACOS" \
        --prefix="$WORK/install-$ARCH" --libdir=lib &&
      make -j"$(sysctl -n hw.ncpu)" build_libs &&
      make install_dev
    } >"$LOG" 2>&1 || { tail -40 "$LOG" >&2; exit 1; }
  )
done

# The generated headers must match, or one include folder can't serve both.
if ! diff -r "$WORK/install-arm64/include" "$WORK/install-x86_64/include" >/dev/null; then
  echo "OpenSSL headers differ between architectures; can't merge them." >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST/lib"
lipo -create "$WORK/install-arm64/lib/libcrypto.a" "$WORK/install-x86_64/lib/libcrypto.a" \
  -output "$DEST/lib/libcrypto.a"
cp -R "$WORK/install-arm64/include" "$DEST/include"
echo "OpenSSL $VERSION, macOS $MIN_MACOS+, $(lipo -archs "$DEST/lib/libcrypto.a")" > "$DEST/VERSION"

echo "Built $DEST ($(cat "$DEST/VERSION"))"
