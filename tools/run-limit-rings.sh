#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/tmp/CodexPetLimitRings.app"
BIN="$APP/Contents/MacOS/CodexPetLimitRings"

pkill -TERM -f "$BIN" 2>/dev/null || true

"$ROOT/tools/build-limit-rings.sh" "$APP" >/dev/null
if [[ "${CODEX_PET_LIMIT_RINGS_NO_MOUSE_MONITOR:-}" == "1" ]]; then
  open -n "$APP" --args --no-mouse-monitor
else
  open -n "$APP"
fi

echo "Codex Pet Limit Rings launched from $APP"
