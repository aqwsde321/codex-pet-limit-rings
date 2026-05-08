#!/usr/bin/env bash
set -euo pipefail

DEFAULT_APP="$HOME/Applications/CodexPetLimitRings.app"
DEFAULT_OLD_APP="$HOME/Applications/CodexLimitAura.app"
APP="${CODEX_PET_LIMIT_RINGS_APP:-$DEFAULT_APP}"
BIN="$APP/Contents/MacOS/CodexPetLimitRings"
AGENT="$HOME/Library/LaunchAgents/com.codex-pet.limit-rings.plist"
OLD_APP="${CODEX_LIMIT_AURA_APP:-$DEFAULT_OLD_APP}"
OLD_BIN="$OLD_APP/Contents/MacOS/CodexLimitAura"
OLD_AGENT="$HOME/Library/LaunchAgents/com.codex-pet.limit-aura.plist"
GUI_TARGET="gui/$(id -u)"

if [[ "$APP" != "$DEFAULT_APP" ]]; then
  echo "Refusing to remove unsafe app path: $APP" >&2
  echo "Use the default path: $DEFAULT_APP" >&2
  exit 2
fi

if [[ "$OLD_APP" != "$DEFAULT_OLD_APP" ]]; then
  echo "Refusing to remove unsafe old app path: $OLD_APP" >&2
  echo "Use the default old app path: $DEFAULT_OLD_APP" >&2
  exit 2
fi

launchctl bootout "$GUI_TARGET" "$AGENT" >/dev/null 2>&1 || true
launchctl bootout "$GUI_TARGET" "$OLD_AGENT" >/dev/null 2>&1 || true
pkill -TERM -f "$BIN" >/dev/null 2>&1 || true
pkill -TERM -f "$OLD_BIN" >/dev/null 2>&1 || true
pkill -TERM -f "CodexPetLimitRings.app/Contents/MacOS/CodexPetLimitRings" >/dev/null 2>&1 || true
pkill -TERM -f "CodexLimitAura.app/Contents/MacOS/CodexLimitAura" >/dev/null 2>&1 || true
rm -f "$AGENT"
rm -f "$OLD_AGENT"
rm -rf "$APP"
rm -rf "$OLD_APP"
defaults delete local.codex.pet-limit-rings CodexPetLimitRings.ringsVisible >/dev/null 2>&1 || true
defaults delete local.codex.pet-limit-rings CodexPetLimitRings.barsOffsetX >/dev/null 2>&1 || true
defaults delete local.codex.pet-limit-rings CodexPetLimitRings.barsOffsetY >/dev/null 2>&1 || true
defaults delete local.codex.pet-limit-rings CodexPetLimitRings.barWidthPreset >/dev/null 2>&1 || true
defaults delete local.codex.pet-limit-rings CodexPetLimitRings.displayStyle >/dev/null 2>&1 || true
defaults delete local.codex.limit-aura CodexLimitAura.ringsVisible >/dev/null 2>&1 || true

echo "Codex Pet Limit Rings uninstalled"
