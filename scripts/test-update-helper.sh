#!/usr/bin/env bash
# test-update-helper.sh
#
# Exercises the detached swap helper OUTSIDE the app: extracts the script
# text from UpdateInstaller.swift via a tiny Swift shim, then drives its
# failure modes against dummy bundles in a temp dir. These paths run after
# NSApp.terminate in production, where nothing else can observe them —
# which is exactly why they get their own harness.
#
# Usage: ./scripts/test-update-helper.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

# Obtain the exact production helper text. The shim MUST be named
# main.swift: swiftc rejects top-level code in any file not named
# main.swift when compiling multiple source files together.
cat > "$WORK/main.swift" <<EOF
import Foundation
print(helperScriptForTesting())
EOF
# helperScriptForTesting is a free function in UpdateInstaller.swift kept
# outside the @MainActor class precisely so this dump can call it.
swiftc -o "$WORK/dump" \
    -enable-upcoming-feature StrictConcurrency \
    "$ROOT/SonosBar/Util/UpdateInstaller.swift" \
    "$ROOT/SonosBar/Util/UpdateManifest.swift" \
    "$ROOT/SonosBar/Util/UpdateChecker.swift" \
    "$ROOT/SonosBar/Util/UpdateSignature.swift" \
    "$ROOT/SonosBar/Util/Log.swift" \
    "$WORK/main.swift"
"$WORK/dump" > "$WORK/swap.sh"

check() { # name condition
    if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; FAILURES=$((FAILURES+1)); fi
}

make_bundle() { # path version
    mkdir -p "$1/Contents/MacOS"
    printf '#!/bin/sh\nsleep 300\n' > "$1/Contents/MacOS/Dummy"
    chmod +x "$1/Contents/MacOS/Dummy"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $2" \
        "$1/Contents/Info.plist" >/dev/null
}

# --- Case 1: wait-loop timeout must leave the bundle untouched ---
make_bundle "$WORK/dst1.app" 1.0.0
make_bundle "$WORK/src1.app" 2.0.0
touch "$WORK/dst1.app/Contents/CANARY"
sleep 300 & HOLD=$!   # a pid that will NOT exit
SB_WAIT_TICKS=3 sh "$WORK/swap.sh" "$HOLD" "$WORK/src1.app" "$WORK/dst1.app" "$WORK/err1" || true
kill "$HOLD" 2>/dev/null || true
check "timeout leaves bundle untouched" '[ -f "$WORK/dst1.app/Contents/CANARY" ]'
check "timeout recorded an error"        '[ -s "$WORK/err1" ]'

# A pid guaranteed to be dead: spawn a no-op and reap it. A literal
# like 99999 can collide with a real long-lived process, hanging the
# helper's wait loop for the full cap.
sh -c 'exit 0' & DEADPID=$!
wait "$DEADPID" 2>/dev/null || true

# --- Case 2: swap failure must restore AND relaunch the original ---
make_bundle "$WORK/dst2.app" 1.0.0
touch "$WORK/dst2.app/Contents/CANARY"
SB_OPEN=/usr/bin/true sh "$WORK/swap.sh" "$DEADPID" "$WORK/nonexistent.app" "$WORK/dst2.app" "$WORK/err2" || true
check "failed swap restores original"   '[ -f "$WORK/dst2.app/Contents/CANARY" ]'
check "failed swap recorded an error"   '[ -s "$WORK/err2" ]'
check "failed swap attempted relaunch"  'grep -q "relaunched-original" "$WORK/err2"'
check "no leftover backup"              '[ ! -e "$WORK/.SonosBar-update-backup" ]'

# --- Case 3: happy path swaps and relaunches the new version ---
make_bundle "$WORK/dst3.app" 1.0.0
make_bundle "$WORK/src3.app" 2.0.0
SB_OPEN=/usr/bin/true sh "$WORK/swap.sh" "$DEADPID" "$WORK/src3.app" "$WORK/dst3.app" "$WORK/err3"
V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$WORK/dst3.app/Contents/Info.plist")
check "happy path installed new version" '[ "$V" = "2.0.0" ]'
check "happy path left no error file"    '[ ! -s "$WORK/err3" ]'
check "happy path left no backup"        '[ ! -e "$WORK/.SonosBar-update-backup" ]'

echo; echo "$((9 - FAILURES))/9 helper checks passed"  # 9 = total check calls
exit $((FAILURES == 0 ? 0 : 1))
