#!/usr/bin/env bash
set -euo pipefail

DEFAULT_APP="$HOME/Applications/CodexPetLimitRings.app"
DEFAULT_OLD_APP="$HOME/Applications/CodexLimitAura.app"
APP="${CODEX_PET_LIMIT_RINGS_APP:-$DEFAULT_APP}"
BIN="$APP/Contents/MacOS/CodexPetLimitRings"
AGENT="$HOME/Library/LaunchAgents/com.codex-pet.limit-rings.plist"
LABEL="com.codex-pet.limit-rings"
OLD_APP="${CODEX_LIMIT_AURA_APP:-$DEFAULT_OLD_APP}"
OLD_BIN="$OLD_APP/Contents/MacOS/CodexLimitAura"
OLD_AGENT="$HOME/Library/LaunchAgents/com.codex-pet.limit-aura.plist"
OLD_LABEL="com.codex-pet.limit-aura"
USER_UID="$(id -u)"
GUI_TARGET="gui/$USER_UID"

process_pattern() {
  local escaped
  escaped="$(printf '%s\n' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
  printf '^%s([[:space:]].*)?$' "$escaped"
}

wait_for_process_exit() {
  local pattern="$1"
  local delay="$2"
  local attempt
  local status
  for attempt in 1 2 3 4 5; do
    if pgrep -f "$pattern" >/dev/null 2>&1; then
      sleep "$delay"
      continue
    fi
    status=$?
    if [[ "$status" -eq 1 ]]; then
      return 0
    fi
    return "$status"
  done
  return 1
}

stop_process() {
  local bin="$1"
  local pattern
  pattern="$(process_pattern "$bin")"

  pkill -TERM -U "$USER_UID" -f "$pattern" >/dev/null 2>&1 || true
  if wait_for_process_exit "$pattern" 0.2; then
    return 0
  fi

  pkill -KILL -U "$USER_UID" -f "$pattern" >/dev/null 2>&1 || true
  if wait_for_process_exit "$pattern" 0.1; then
    return 0
  fi

  echo "Failed to stop process: $bin" >&2
  return 1
}

bootout_agent() {
  local label="$1"
  local agent="$2"
  launchctl bootout "$GUI_TARGET/$label" >/dev/null 2>&1 ||
    launchctl bootout "$GUI_TARGET" "$agent" >/dev/null 2>&1 || true
}

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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bootout_agent "$LABEL" "$AGENT"
bootout_agent "$OLD_LABEL" "$OLD_AGENT"
rm -f "$AGENT"
rm -f "$OLD_AGENT"

stop_process "$BIN"
stop_process "$OLD_BIN"

if launchctl print "$GUI_TARGET/$LABEL" >/dev/null 2>&1 ||
  launchctl print "$GUI_TARGET/$OLD_LABEL" >/dev/null 2>&1; then
  echo "Failed to unload Codex Pet Limit Rings LaunchAgent" >&2
  exit 1
fi

"$ROOT/tools/cleanup-legacy-turn-usage.sh"

rm -rf "$APP"
rm -rf "$OLD_APP"
rm -f "$HOME/Library/Logs/CodexPetLimitRings.log" "$HOME/Library/Logs/CodexPetLimitRings.err.log"
defaults delete local.codex.pet-limit-rings >/dev/null 2>&1 || true
defaults delete local.codex.limit-aura >/dev/null 2>&1 || true
rm -f \
  "$HOME/Library/Preferences/local.codex.pet-limit-rings.plist" \
  "$HOME/Library/Preferences/local.codex.limit-aura.plist"

echo "Codex Pet Limit Rings uninstalled"
