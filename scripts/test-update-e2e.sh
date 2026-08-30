#!/usr/bin/env bash
# test-update-e2e.sh
#
# Full-cycle proof: builds the CURRENT tree twice (as versions 98.0.0 and
# 99.0.0), signs a manifest with throwaway keys, serves it over localhost,
# installs 98.0.0 into a temp dir, launches it with debug feed+auto-install
# overrides, and verifies it replaces itself with 99.0.0 and relaunches.
#
# Run manually before any release that touches the updater. NOT in CI:
# it launches a real GUI app (SSDP discovery, hotkey registration).
# QUIRK: uses the app's real bundle id defaults domain; restores the
# debug keys afterwards.
#
# PREREQUISITE: quit the user's real SonosBar (from /Applications) before
# running this. It shares the bundle id app.sonosbar.SonosBar with the
# temp copy this script launches — with the real app already running,
# `open` on the temp copy just activates the real one instead of
# starting a second process, which silently produces a spurious
# 60s-timeout FAIL with nothing actually tested. Restart the real app
# afterwards; this script does not do that for you.
#
# Modes:
#   * Default (Xcode present): builds v98 and v99 from the current tree
#     via scripts/build-app.sh, mutating and restoring the repo's
#     SonosBar/Resources/Info.plist around each build.
#   * Prebuilt (E2E_PREBUILT_APP=/path/to/SonosBar.app): for CLT-only
#     machines that cannot run `swift build`. The prebuilt app MUST be a
#     debug build (`build-app.sh debug`): the feed-URL override and
#     auto-install seams this test relies on are #if DEBUG and are absent
#     from a release build. Skips the build entirely —
#     ditto's the prebuilt .app into the version's outdir twice (once
#     per version) and patches EACH COPY's Info.plist in place with
#     PlistBuddy, then re-signs the copy ad-hoc (PlistBuddy invalidates
#     the existing signature; the app won't launch without a fresh seal).
#     The repo's SonosBar/Resources/Info.plist is never touched in this
#     mode — only the copies.
#
# Usage:
#   ./scripts/test-update-e2e.sh
#   E2E_PREBUILT_APP=/path/to/SonosBar.app ./scripts/test-update-e2e.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
PORT=8788

if [ -n "${E2E_PREBUILT_APP:-}" ]; then
    echo "==> Mode: prebuilt (E2E_PREBUILT_APP=$E2E_PREBUILT_APP) — repo Info.plist will NOT be touched"
else
    echo "==> Mode: build (swift build via scripts/build-app.sh)"
fi

cleanup() {
    # Kill only processes running from copies under our own WORK dir —
    # never anything under /Applications.
    pkill -f "$WORK/install/SonosBar.app" 2>/dev/null || true
    pkill -f "$WORK/old/SonosBar.app" 2>/dev/null || true
    pkill -f "$WORK/new/SonosBar.app" 2>/dev/null || true
    pkill -f "http.server $PORT" 2>/dev/null || true
    defaults delete app.sonosbar.SonosBar debug.updateFeedURL 2>/dev/null || true
    defaults delete app.sonosbar.SonosBar debug.updateAutoInstall 2>/dev/null || true
    # Restore the tree's plist. Lives in the trap (not just inline after
    # the builds) so a set -e abort mid-run — build failure, missing
    # tool, anything — still restores the tree instead of leaving it
    # stamped 98.0.0/99.0.0 with a throwaway SBUpdatePublicKey whose
    # private half is already gone (committing that would ship an app
    # that can never verify a future update). Guarded for both mode
    # (prebuilt never touches the tree) and unset-var safety (an abort
    # before ORIG_VER is captured must not write an empty version).
    if [ -z "${E2E_PREBUILT_APP:-}" ] && [ -n "${ORIG_VER:-}" ]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ORIG_VER" "$ROOT/SonosBar/Resources/Info.plist"
        /usr/libexec/PlistBuddy -c "Set :SBUpdatePublicKey ${ORIG_PUB:-}" "$ROOT/SonosBar/Resources/Info.plist"
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> Throwaway signing keys"
KEYS=$(swift "$ROOT/scripts/generate-update-keys.swift")
PUB=$(echo "$KEYS" | awk '/^PUBLIC:/{print $2}')
PRIV=$(echo "$KEYS" | awk '/^PRIVATE:/{print $2}')

if [ -n "${E2E_PREBUILT_APP:-}" ]; then
    build_version() { # version outdir
        mkdir -p "$2"
        ditto "$E2E_PREBUILT_APP" "$2/SonosBar.app"
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $1" \
            "$2/SonosBar.app/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $1" \
            "$2/SonosBar.app/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c "Set :SBUpdatePublicKey $PUB" \
            "$2/SonosBar.app/Contents/Info.plist"
        # PlistBuddy edits the sealed Info.plist, which invalidates the
        # existing ad-hoc signature. Re-seal, or the copy won't launch.
        codesign --force --deep --sign - "$2/SonosBar.app"
    }
else
    build_version() { # version outdir
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $1" "$ROOT/SonosBar/Resources/Info.plist"
        /usr/libexec/PlistBuddy -c "Set :SBUpdatePublicKey $PUB" "$ROOT/SonosBar/Resources/Info.plist"
        # Debug config on purpose: the feed-URL override and auto-install
        # seams this test drives are #if DEBUG (compiled out of release
        # builds). Package.swift defines DEBUG for the debug configuration.
        (cd "$ROOT" && ./scripts/build-app.sh debug >/dev/null)
        mkdir -p "$2"
        ditto "$ROOT/build/SonosBar.app" "$2/SonosBar.app"
    }
fi

if [ -n "${E2E_PREBUILT_APP:-}" ]; then
    echo "==> Stamping v98 and v99 copies of the prebuilt app"
else
    echo "==> Building v98 and v99 from the current tree"
    ORIG_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/SonosBar/Resources/Info.plist")
    ORIG_PUB=$(/usr/libexec/PlistBuddy -c "Print :SBUpdatePublicKey" "$ROOT/SonosBar/Resources/Info.plist" 2>/dev/null || echo "")
fi
build_version 98.0.0 "$WORK/old"
build_version 99.0.0 "$WORK/new"
# Restore happens in the cleanup trap (see above) so it still runs on
# a mid-run abort, not just on this successful path.

echo "==> Signed manifest for v99"
mkdir -p "$WORK/serve"
(cd "$WORK/new" && ditto -c -k --keepParent SonosBar.app "$WORK/serve/SonosBar-99.0.0.app.zip")
SHA=$(shasum -a 256 "$WORK/serve/SonosBar-99.0.0.app.zip" | awk '{print $1}')
printf '{"version":"99.0.0","build":"99.0.0","url":"http://127.0.0.1:%s/SonosBar-99.0.0.app.zip","sha256":"%s","bundleIdentifier":"app.sonosbar.SonosBar","minimumSystemVersion":"26.0","releaseNotesURL":"http://127.0.0.1:%s/notes","pubDate":"2026-01-01T00:00:00Z"}' \
    "$PORT" "$SHA" "$PORT" > "$WORK/serve/appcast.json"
UPDATE_ED_PRIVATE_KEY="$PRIV" swift "$ROOT/scripts/sign-update.swift" "$WORK/serve/appcast.json"

echo "==> Serving feed on :$PORT; installing v98"
(cd "$WORK/serve" && nohup python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 &)
# Bounded wait: python needs a beat to bind before it'll answer.
for _ in $(seq 1 40); do
    curl -fsS "http://127.0.0.1:$PORT/appcast.json" >/dev/null 2>&1 && break
    sleep 0.25
done
curl -fsS "http://127.0.0.1:$PORT/appcast.json" >/dev/null || { echo "server failed to start"; exit 1; }
mkdir -p "$WORK/install"
ditto "$WORK/old/SonosBar.app" "$WORK/install/SonosBar.app"
defaults write app.sonosbar.SonosBar debug.updateFeedURL "http://127.0.0.1:$PORT/appcast.json"
defaults write app.sonosbar.SonosBar debug.updateAutoInstall -bool true

echo "==> Launching v98 (it should replace itself with v99)"
open "$WORK/install/SonosBar.app"
for i in $(seq 1 60); do
    V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
        "$WORK/install/SonosBar.app/Contents/Info.plist" 2>/dev/null || echo "?")
    [ "$V" = "99.0.0" ] && break
    sleep 1
done

V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$WORK/install/SonosBar.app/Contents/Info.plist")
RUNNING=$(pgrep -f "$WORK/install/SonosBar.app" | head -1 || true)
echo "installed version: $V; running pid: ${RUNNING:-none}"
if [ "$V" = "99.0.0" ] && [ -n "$RUNNING" ]; then
    echo "E2E: PASS — app replaced itself and relaunched"
else
    echo "E2E: FAIL"; exit 1
fi
