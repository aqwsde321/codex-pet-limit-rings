#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/tmp/test-limit-rings-usage"
MODULE_CACHE="$ROOT/tmp/swift-module-cache"
TESTABLE_SOURCE="$ROOT/tmp/codex-pet-limit-rings-testable.swift"

mkdir -p "$ROOT/tmp" "$MODULE_CACHE"
awk '/^\/\/ LIMIT_RINGS_MAIN_BEGIN$/ { exit } { print }' \
    "$ROOT/tools/codex-pet-limit-rings.swift" \
    > "$TESTABLE_SOURCE"
swiftc -D LIMIT_RINGS_TESTING \
    -module-cache-path "$MODULE_CACHE" \
    "$TESTABLE_SOURCE" \
    "$ROOT/tools/test-limit-rings-usage.swift" \
    -o "$BIN" \
    -framework AppKit \
    -lsqlite3
"$BIN"
