#!/usr/bin/env bash
# Copies the parts of UxPlay and libplist that Flect builds on into
# Sources/AirPlayCore, then applies Flect's patches (patches/). Re-run it
# with a newer commit or version to refresh the copies.
#
# Usage: scripts/vendor.sh [uxplay-commit]
set -euo pipefail

UXPLAY_REPO=https://github.com/FDH2/UxPlay.git
UXPLAY_COMMIT=${1:-57ea83411d5f7e0b38c5841987439340543f025c}
LIBPLIST_VERSION=2.7.0
LIBPLIST_SHA256=7ac42301e896b1ebe3c654634780c82baa7cb70df8554e683ff89f7c2643eb8b

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$ROOT/Sources/AirPlayCore"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Fetching UxPlay $UXPLAY_COMMIT"
git clone --quiet "$UXPLAY_REPO" "$WORK/uxplay"
git -C "$WORK/uxplay" checkout --quiet "$UXPLAY_COMMIT"
LIB="$WORK/uxplay/lib"

rm -rf "$DEST/uxplay"
mkdir -p "$DEST/uxplay/playfair" "$DEST/uxplay/llhttp" "$DEST/uxplay/dns_sd"
cp "$LIB"/*.[ch] "$DEST/uxplay/"
cp "$LIB"/playfair/*.[ch] "$LIB/playfair/LICENSE.md" "$DEST/uxplay/playfair/"
cp "$LIB"/llhttp/*.[ch] "$LIB/llhttp/LICENSE-MIT" "$DEST/uxplay/llhttp/"
cp "$LIB"/dns_sd/*.[ch] "$DEST/uxplay/dns_sd/"
cp "$WORK/uxplay/LICENSE" "$DEST/uxplay/LICENSE"
echo "$UXPLAY_REPO $UXPLAY_COMMIT" > "$DEST/uxplay/VERSION"

# Flect's changes to the library, kept as patches so updates stay easy.
for PATCH in "$ROOT"/patches/uxplay-*.patch; do
  [[ -e "$PATCH" ]] || continue
  echo "Applying $(basename "$PATCH")"
  patch -p1 --quiet --forward -d "$DEST/uxplay" < "$PATCH"
  echo "patched with $(basename "$PATCH")" >> "$DEST/uxplay/VERSION"
done

echo "Fetching libplist $LIBPLIST_VERSION"
curl -fsSL -o "$WORK/libplist.tar.bz2" \
  "https://github.com/libimobiledevice/libplist/releases/download/$LIBPLIST_VERSION/libplist-$LIBPLIST_VERSION.tar.bz2"
echo "$LIBPLIST_SHA256  $WORK/libplist.tar.bz2" | shasum -a 256 -c - >/dev/null
tar -xjf "$WORK/libplist.tar.bz2" -C "$WORK"
SRC="$WORK/libplist-$LIBPLIST_VERSION"

rm -rf "$DEST/libplist"
mkdir -p "$DEST/libplist/src" "$DEST/libplist/include/plist" "$DEST/libplist/libcnary/include"
cp "$SRC"/src/*.[ch] "$DEST/libplist/src/"
cp "$SRC/include/plist/plist.h" "$DEST/libplist/include/plist/"
cp "$SRC"/libcnary/*.c "$DEST/libplist/libcnary/"
cp "$SRC"/libcnary/include/*.h "$DEST/libplist/libcnary/include/"
cp "$SRC/COPYING.LESSER" "$DEST/libplist/COPYING.LESSER"
echo "libplist $LIBPLIST_VERSION" > "$DEST/libplist/VERSION"

echo "Vendored into $DEST"
