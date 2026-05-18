#!/usr/bin/env bash
# sign-and-notarize.sh
# Real codesigning + notarization for release distribution.
#
# Prerequisites:
#   * A Developer ID Application certificate in your login keychain.
#     ("Developer ID Application: Your Name (TEAMID)" — NOT a Mac App
#     Store certificate. Get one at developer.apple.com.)
#   * An app-specific password for notarization, stored in keychain via:
#       xcrun notarytool store-credentials sonosbar-notary \
#         --apple-id you@example.com --team-id ABCDEFGHIJ \
#         --password "abcd-efgh-ijkl-mnop"
#
# Usage:
#   ./scripts/sign-and-notarize.sh "Developer ID Application: Your Name (TEAMID)"
#
# Output: build/SonosBar.app, signed and stapled.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 \"Developer ID Application: ...\"" >&2
    exit 1
fi

IDENTITY="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/SonosBar.app"

if [ ! -d "$APP" ]; then
    echo "Build the app first: ./scripts/build-app.sh release" >&2
    exit 1
fi

echo "==> Stripping ad-hoc signature"
codesign --remove-signature "$APP" || true

echo "==> Signing with $IDENTITY"
codesign --force --deep --options runtime \
    --entitlements "$ROOT/SonosBar/Resources/SonosBar.entitlements" \
    --sign "$IDENTITY" \
    --timestamp \
    "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Zipping for notarization"
ZIP="$ROOT/build/SonosBar-notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to notary service (this can take a few minutes)"
xcrun notarytool submit "$ZIP" \
    --keychain-profile sonosbar-notary \
    --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

rm "$ZIP"

echo "==> Done. Signed + notarized app at $APP"
