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

# A pid guaranteed to be dead: spawn a no-op and reap it, up front, so
# every non-timeout case below can reuse it. A literal like 99999 can
# collide with a real long-lived process, hanging the helper's wait loop
# for the full cap.
sh -c 'exit 0' & DEADPID=$!
wait "$DEADPID" 2>/dev/null || true

# --- Case 1: wait-loop timeout must leave the bundle untouched ---
make_bundle "$WORK/dst1.app" 1.0.0
make_bundle "$WORK/src1.app" 2.0.0
touch "$WORK/dst1.app/Contents/CANARY"
sleep 300 & HOLD=$!   # a pid that will NOT exit
SB_WAIT_TICKS=3 sh "$WORK/swap.sh" "$HOLD" "$WORK/src1.app" "$WORK/dst1.app" "$WORK/err1" || true
kill "$HOLD" 2>/dev/null || true
check "timeout leaves bundle untouched"      '[ -f "$WORK/dst1.app/Contents/CANARY" ]'
check "timeout recorded an error"            '[ -s "$WORK/err1" ]'
check "timeout left no staging leftover"     '[ ! -e "$WORK/.SonosBar-update-staging" ]'

# --- Case 2: a missing payload must leave the bundle untouched before
# anything is renamed (the staged-copy sequence's first gate) ---
make_bundle "$WORK/dst2.app" 1.0.0
touch "$WORK/dst2.app/Contents/CANARY"
RC2=0
sh "$WORK/swap.sh" "$DEADPID" "$WORK/nonexistent.app" "$WORK/dst2.app" "$WORK/err2" || RC2=$?
check "missing SRC leaves bundle untouched"  '[ -f "$WORK/dst2.app/Contents/CANARY" ]'
check "missing SRC recorded an error"        '[ -s "$WORK/err2" ]'
check "missing SRC exits 1"                  '[ "$RC2" = 1 ]'
check "missing SRC left no staging leftover" '[ ! -e "$WORK/.SonosBar-update-staging" ]'

# --- Case 3: a failed final rename onto DST must restore AND relaunch
# the original. Forcing that rename to fail needs either a filesystem
# race or a deliberate seam; SB_FORCE_RESTORE is the seam — it drops the
# staged copy right before the rename, which is a real rename failure
# (ENOENT), not a stubbed-out branch. SB_OPEN points at a marker script
# instead of /usr/bin/true so relaunch is verified as an actual
# invocation carrying DST as its argument, not inferred from error text
# alone (grepping "relaunched-original" alone is vacuous: fail() prints
# it unconditionally even if the open call above it were deleted).
make_bundle "$WORK/dst3.app" 1.0.0
make_bundle "$WORK/src3.app" 2.0.0
touch "$WORK/dst3.app/Contents/CANARY"
OPEN_MARKER="$WORK/open-marker"
rm -f "$OPEN_MARKER"
cat > "$WORK/fake-open.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$OPEN_MARKER"
exit 0
EOF
chmod +x "$WORK/fake-open.sh"
SB_FORCE_RESTORE=1 SB_OPEN="$WORK/fake-open.sh" \
    sh "$WORK/swap.sh" "$DEADPID" "$WORK/src3.app" "$WORK/dst3.app" "$WORK/err3" || true
check "failed swap restores original"           '[ -f "$WORK/dst3.app/Contents/CANARY" ]'
check "failed swap recorded an error"           '[ -s "$WORK/err3" ]'
check "failed swap attempted relaunch"          'grep -q "relaunched-original" "$WORK/err3"'
check "failed swap actually invoked open with dst" \
    '[ -f "$OPEN_MARKER" ] && grep -qF "$WORK/dst3.app" "$OPEN_MARKER"'
check "no leftover backup after failed swap"    '[ ! -e "$WORK/.SonosBar-update-backup" ]'
check "no leftover staging after failed swap"   '[ ! -e "$WORK/.SonosBar-update-staging" ]'

# --- Case 4: happy path swaps and relaunches the new version. The error
# file is seeded with stale content from a fictitious earlier failure
# first: a successful swap must truncate it immediately, not merely
# leave it alone because nothing new got written this run. ---
make_bundle "$WORK/dst4.app" 1.0.0
make_bundle "$WORK/src4.app" 2.0.0
printf 'stale error from a previous run\n' > "$WORK/err4"
SB_OPEN=/usr/bin/true sh "$WORK/swap.sh" "$DEADPID" "$WORK/src4.app" "$WORK/dst4.app" "$WORK/err4"
V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$WORK/dst4.app/Contents/Info.plist")
check "happy path installed new version"     '[ "$V" = "2.0.0" ]'
check "happy path truncates stale error"     '[ ! -s "$WORK/err4" ]'
check "happy path left no backup"            '[ ! -e "$WORK/.SonosBar-update-backup" ]'
check "happy path left no staging"           '[ ! -e "$WORK/.SonosBar-update-staging" ]'

TOTAL=17
echo; echo "$((TOTAL - FAILURES))/$TOTAL helper checks passed"
exit $((FAILURES == 0 ? 0 : 1))
