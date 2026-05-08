#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/tmp/CodexPetLimitRings.app}"
BIN="$APP/Contents/MacOS/CodexPetLimitRings"

case "$APP" in
  "$ROOT"/tmp/*.app|"$HOME"/Applications/CodexPetLimitRings.app) ;;
  *)
    echo "Refusing to build into unsafe app path: $APP" >&2
    echo "Use $ROOT/tmp/*.app or $HOME/Applications/CodexPetLimitRings.app" >&2
    exit 2
    ;;
esac

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/tools/CodexPetLimitRings-Info.plist" "$APP/Contents/Info.plist"
swiftc "$ROOT/tools/codex-pet-limit-rings.swift" -o "$BIN" -framework AppKit -lsqlite3

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "$APP"
