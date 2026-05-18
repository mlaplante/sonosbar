#!/usr/bin/env bash
# make-dmg.sh
# Wraps a signed, notarized SonosBar.app in a .dmg for distribution.
#
# Uses macOS's built-in hdiutil — no third-party tools required.
#
# Usage (after sign-and-notarize.sh):
#   ./scripts/make-dmg.sh
#
# Output: dist/SonosBar-0.1.0.dmg

set -euo pipefail

VERSION="${SONOSBAR_VERSION:-0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/SonosBar.app"
DIST_DIR="$ROOT/dist"
STAGING="$ROOT/build/dmg-staging"
DMG="$DIST_DIR/SonosBar-$VERSION.dmg"

if [ ! -d "$APP" ]; then
    echo "Build + sign first: ./scripts/build-app.sh release && ./scripts/sign-and-notarize.sh \"...\"" >&2
    exit 1
fi

mkdir -p "$DIST_DIR"
rm -rf "$STAGING"
mkdir -p "$STAGING"

# Stage the .app and a symlink to /Applications for the classic drag-to-install UX.
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Tear down any previous dmg of the same name.
[ -f "$DMG" ] && rm "$DMG"

echo "==> Creating $DMG"
hdiutil create -volname "SonosBar" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG"

# Sign the dmg too — Gatekeeper checks both the app and its container.
if [ -n "${1:-}" ]; then
    IDENTITY="$1"
    echo "==> Signing DMG with $IDENTITY"
    codesign --sign "$IDENTITY" --timestamp "$DMG"

    echo "==> Notarizing DMG"
    xcrun notarytool submit "$DMG" --keychain-profile sonosbar-notary --wait
    xcrun stapler staple "$DMG"
fi

rm -rf "$STAGING"
echo "==> Done. DMG at $DMG"
