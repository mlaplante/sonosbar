#!/usr/bin/env bash
# run-parser-tests.sh
#
# Compiles the production parser sources together with the plain
# executable test harness and runs it against the sanitized fixtures.
#
# Why not an XCTest/SPM test target: the harness must run on Command
# Line Tools-only machines, which ship neither the XCTest runtime nor
# the SwiftUI macro plugins an app-wide test target would drag in.
# Compiling the transport/util/discovery layers directly keeps the
# tests honest (real production files, same strict-concurrency flags)
# without restructuring the package.
#
# Usage: ./scripts/run-parser-tests.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build/parser-tests"
mkdir -p "$BUILD_DIR"

echo "==> Compiling parser test harness"
swiftc -o "$BUILD_DIR/parser-tests" \
    -enable-upcoming-feature StrictConcurrency \
    -enable-upcoming-feature ExistentialAny \
    "$ROOT"/SonosBar/Transport/*.swift \
    "$ROOT"/SonosBar/Util/*.swift \
    "$ROOT"/SonosBar/Discovery/*.swift \
    "$ROOT"/Tests/ParserTests/main.swift

echo "==> Running"
"$BUILD_DIR/parser-tests" "$ROOT/Tests/ParserTests/Fixtures"
