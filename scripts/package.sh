#!/usr/bin/env bash
# Makes the files to hand out, in dist/:
#   Flect-<version>.pkg   installer for IT to deploy (puts Flect in /Applications)
#   Flect-<version>.zip   the app on its own
#   SHA256SUMS
# Both run on Apple silicon and Intel Macs with macOS 14 or later.
#
# Usage: scripts/package.sh
# Environment: FLECT_VERSION, FLECT_BUILD, FLECT_BUNDLE_ID, FLECT_SIGN_IDENTITY
# (see build-app.sh). Without a Developer ID the results are unsigned: see
# "Installing on school Macs" in the README.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

export FLECT_VERSION=${FLECT_VERSION:-$(tr -d '[:space:]' < VERSION)}
export FLECT_BUNDLE_ID=${FLECT_BUNDLE_ID:-org.flect.Flect}

if [[ -z "${FLECT_OPENSSL_PREFIX:-}" && ! -f build/openssl/lib/libcrypto.a ]]; then
  scripts/build-openssl.sh
fi
scripts/build-app.sh release --universal

APP="$ROOT/build/Flect.app"
DIST="$ROOT/dist"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
rm -rf "$DIST"
mkdir -p "$DIST"

# The app on its own. Extended attributes are left out: an app doesn't need
# them, and they'd show up as a __MACOSX folder in other unzip tools.
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$DIST/Flect-$FLECT_VERSION.zip"

# The installer.
mkdir -p "$WORK/root"
ditto "$APP" "$WORK/root/Flect.app"
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist" >/dev/null
# Always install into /Applications, even if a copy of Flect exists elsewhere.
plutil -replace 0.BundleIsRelocatable -bool false "$WORK/components.plist"
pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" \
  --install-location /Applications --identifier "$FLECT_BUNDLE_ID" --version "$FLECT_VERSION" \
  "$WORK/Flect-component.pkg" >/dev/null
sed -e "s/__BUNDLE_ID__/$FLECT_BUNDLE_ID/g" -e "s/__VERSION__/$FLECT_VERSION/g" \
  Resources/distribution.xml > "$WORK/distribution.xml"
productbuild --distribution "$WORK/distribution.xml" --package-path "$WORK" \
  "$DIST/Flect-$FLECT_VERSION.pkg" >/dev/null

(cd "$DIST" && shasum -a 256 Flect-* > SHA256SUMS)

echo "Made:"
ls -lh "$DIST" | awk 'NR > 1 { print "  " $NF "  " $5 }'
