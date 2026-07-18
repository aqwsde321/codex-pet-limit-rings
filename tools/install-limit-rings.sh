#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_APP="$HOME/Applications/CodexPetLimitRings.app"
DEFAULT_OLD_APP="$HOME/Applications/CodexLimitAura.app"
APP="${CODEX_PET_LIMIT_RINGS_APP:-$DEFAULT_APP}"
BIN="$APP/Contents/MacOS/CodexPetLimitRings"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT="$AGENT_DIR/com.codex-pet.limit-rings.plist"
OLD_APP="${CODEX_LIMIT_AURA_APP:-$DEFAULT_OLD_APP}"
OLD_BIN="$OLD_APP/Contents/MacOS/CodexLimitAura"
OLD_AGENT="$AGENT_DIR/com.codex-pet.limit-aura.plist"
GUI_TARGET="gui/$(id -u)"
EXTRA_ARG_PLIST=""

if [[ "${CODEX_PET_LIMIT_RINGS_NO_MOUSE_MONITOR:-}" == "1" ]]; then
  EXTRA_ARG_PLIST="    <string>--no-mouse-monitor</string>"
fi

if [[ "$APP" != "$DEFAULT_APP" ]]; then
  echo "Refusing to install into unsafe app path: $APP" >&2
  echo "Use the default path: $DEFAULT_APP" >&2
  exit 2
fi

if [[ "$OLD_APP" != "$DEFAULT_OLD_APP" ]]; then
  echo "Refusing to remove unsafe old app path: $OLD_APP" >&2
  echo "Use the default old app path: $DEFAULT_OLD_APP" >&2
  exit 2
fi

"$ROOT/tools/cleanup-legacy-turn-usage.sh"

mkdir -p "$(dirname "$APP")" "$AGENT_DIR" "$HOME/Library/Logs"

launchctl bootout "$GUI_TARGET" "$AGENT" >/dev/null 2>&1 || true
launchctl bootout "$GUI_TARGET" "$OLD_AGENT" >/dev/null 2>&1 || true
pkill -TERM -f "$BIN" >/dev/null 2>&1 || true
pkill -TERM -f "$OLD_BIN" >/dev/null 2>&1 || true
pkill -TERM -f "CodexPetLimitRings.app/Contents/MacOS/CodexPetLimitRings" >/dev/null 2>&1 || true
pkill -TERM -f "CodexLimitAura.app/Contents/MacOS/CodexLimitAura" >/dev/null 2>&1 || true
rm -f "$OLD_AGENT"
rm -rf "$OLD_APP"

"$ROOT/tools/build-limit-rings.sh" "$APP" >/dev/null

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.codex-pet.limit-rings</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
$EXTRA_ARG_PLIST
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/CodexPetLimitRings.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/CodexPetLimitRings.err.log</string>
</dict>
</plist>
PLIST

launchctl bootstrap "$GUI_TARGET" "$AGENT"
launchctl kickstart -k "$GUI_TARGET/com.codex-pet.limit-rings"

echo "Codex Pet Limit Rings installed at $APP"
echo "Menu bar item: Codex Pet Limit Rings icon"
