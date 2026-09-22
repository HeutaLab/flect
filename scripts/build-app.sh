#!/usr/bin/env bash
# Builds build/Flect.app.
#
# Usage: scripts/build-app.sh [release|debug] [--universal]
#   --universal   Apple silicon and Intel in one app. Needs the universal
#                 OpenSSL from scripts/build-openssl.sh.
#
# Environment:
#   FLECT_BUNDLE_ID       bundle identifier (default org.flect.Flect)
#   FLECT_VERSION         marketing version (default: the VERSION file)
#   FLECT_BUILD           build number (default: the number of commits)
#   FLECT_SIGN_IDENTITY   codesign identity, e.g. "Developer ID Application: …"
#                         (default "-": ad hoc, which runs but isn't trusted by
#                         Gatekeeper when downloaded)
#   FLECT_OPENSSL_PREFIX  OpenSSL to link statically (see Package.swift)
set -euo pipefail

CONFIGURATION=release
ARCH_FLAGS=()
for ARG in "$@"; do
  case "$ARG" in
    release|debug) CONFIGURATION=$ARG ;;
    --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
    *) echo "usage: scripts/build-app.sh [release|debug] [--universal]" >&2; exit 64 ;;
  esac
done

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

BUNDLE_ID=${FLECT_BUNDLE_ID:-org.flect.Flect}
VERSION=${FLECT_VERSION:-$(tr -d '[:space:]' < VERSION)}
BUILD=${FLECT_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
SIGN_IDENTITY=${FLECT_SIGN_IDENTITY:--}

if [[ ${#ARCH_FLAGS[@]} -gt 0 && -z "${FLECT_OPENSSL_PREFIX:-}" && ! -f build/openssl/lib/libcrypto.a ]]; then
  echo "A universal build needs a universal OpenSSL: run scripts/build-openssl.sh first." >&2
  exit 1
fi

# (The odd expansion keeps macOS's bash 3.2 happy when the array is empty.)
swift build -c "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product Flect
BIN_DIR=$(swift build -c "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)

APP="$ROOT/build/Flect.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Flect" "$APP/Contents/MacOS/Flect"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
    -e "s/__VERSION__/$VERSION/" \
    -e "s/__BUILD__/$BUILD/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Hardened runtime, as notarization requires. Flect needs no entitlements:
# it isn't sandboxed, and everything it uses is linked in statically.
codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP"

echo "Built $APP $VERSION ($BUILD), $(lipo -archs "$APP/Contents/MacOS/Flect")"
