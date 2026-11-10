#!/usr/bin/env bash
# build-app.sh
# Wraps the SPM executable output in a proper .app bundle.
#
# Why this exists:
#   `swift build` produces a plain Mach-O executable at
#   .build/release/SonosBar. For a menu bar app, macOS needs a proper
#   .app bundle structure with Info.plist and entitlements, otherwise
#   LSUIElement is ignored and the app shows a Dock icon (or fails to
#   register as an agent app at all).
#
# Usage:
#   ./scripts/build-app.sh              # debug build
#   ./scripts/build-app.sh release      # release build
#
# Output: build/SonosBar.app
#
# Codesigning + notarization arrive in chunk 11; for development you
# can just run the .app directly — Gatekeeper will prompt the first
# time and remember thereafter.

set -euo pipefail

CONFIG="${1:-debug}"
APP_NAME="SonosBar"
BUNDLE_ID="app.sonosbar.SonosBar"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Building $APP_NAME ($CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG"

BIN_PATH="$ROOT/.build/$CONFIG/$APP_NAME"
if [ ! -f "$BIN_PATH" ]; then
    echo "ERROR: build output not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling .app bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

# Executable
cp "$BIN_PATH" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"

# Info.plist — the SPM build doesn't embed this for executable targets.
cp "$ROOT/SonosBar/Resources/Info.plist" "$CONTENTS/Info.plist"

# Asset catalog — SPM compiles .xcassets into a .bundle inside .build;
# we copy that compiled bundle into Resources/ so the app finds it at runtime.
COMPILED_BUNDLE="$ROOT/.build/$CONFIG/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$COMPILED_BUNDLE" ]; then
    cp -R "$COMPILED_BUNDLE" "$RESOURCES/"
fi

# PkgInfo — a 1990s holdover macOS still expects for proper app bundles.
printf "APPL????" > "$CONTENTS/PkgInfo"

# Signing. SONOSBAR_SIGN_IDENTITY selects a stable identity (Developer ID
# or a self-signed code-signing cert, by name or SHA-1) so every build has
# the same designated requirement — TCC grants such as Local Network and the
# SMAppService login item then survive self-updates. Unset = ad-hoc, which
# is fine for local development but gives each build a new identity.
IDENTITY="${SONOSBAR_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
    echo "==> Ad-hoc signing (set SONOSBAR_SIGN_IDENTITY for a stable identity)"
    codesign --force --deep --sign - \
        --entitlements "$ROOT/SonosBar/Resources/SonosBar.entitlements" \
        "$APP_DIR"
else
    echo "==> Signing with identity: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" \
        --options runtime \
        --identifier app.sonosbar.SonosBar \
        --entitlements "$ROOT/SonosBar/Resources/SonosBar.entitlements" \
        "$APP_DIR"
    codesign --verify --deep --strict "$APP_DIR"
fi

echo "==> Done: $APP_DIR"
echo "    Run with: open '$APP_DIR'"
