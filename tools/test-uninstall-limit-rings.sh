#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-pet-uninstall.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

TEST_HOME="$TEST_ROOT/home"
TEST_CODEX_HOME="$TEST_HOME/.codex"
STUB_BIN="$TEST_ROOT/bin"
PROCESS_STATE="$TEST_ROOT/processes"
DEFAULTS_STATE="$TEST_ROOT/defaults"
LAUNCH_LOG="$TEST_ROOT/launchctl.log"
mkdir -p "$STUB_BIN" "$PROCESS_STATE" "$DEFAULTS_STATE"
export TEST_PROCESS_STATE="$PROCESS_STATE"
export TEST_DEFAULTS_STATE="$DEFAULTS_STATE"
export TEST_LAUNCH_LOG="$LAUNCH_LOG"

cat > "$STUB_BIN/launchctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  bootout) printf '%s\n' "$*" >> "$TEST_LAUNCH_LOG" ;;
  print) exit 1 ;;
  *) exit 2 ;;
esac
SH

cat > "$STUB_BIN/process-command" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
pattern="${!#}"
case "$pattern" in
  *CodexPetLimitRings*) marker="$TEST_PROCESS_STATE/CodexPetLimitRings" ;;
  *) exit 1 ;;
esac

if [[ "${0##*/}" == "pgrep" ]]; then
  [[ -e "$marker" ]]
  exit
fi

[[ -e "$marker" ]] || exit 1
case "${1:-}" in
  -TERM) exit 0 ;;
  -KILL)
    [[ "${TEST_KILL_FAIL:-0}" != "1" ]] || exit 1
    rm -f "$marker"
    ;;
  *) exit 2 ;;
esac
SH

cat > "$STUB_BIN/defaults" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "delete" ]] || exit 2
domain="$TEST_DEFAULTS_STATE/${2:?}"
if [[ $# -eq 2 ]]; then
  rm -rf "$domain"
else
  rm -f "$domain/${3:?}"
  rmdir "$domain" >/dev/null 2>&1 || true
fi
SH

chmod +x "$STUB_BIN/launchctl" "$STUB_BIN/process-command" "$STUB_BIN/defaults"
ln -s process-command "$STUB_BIN/pkill"
ln -s process-command "$STUB_BIN/pgrep"
ln -s /usr/bin/true "$STUB_BIN/sleep"

APP="$TEST_HOME/Applications/CodexPetLimitRings.app"
OLD_APP="$TEST_HOME/Applications/CodexLimitAura.app"
AGENT="$TEST_HOME/Library/LaunchAgents/com.codex-pet.limit-rings.plist"
OLD_AGENT="$TEST_HOME/Library/LaunchAgents/com.codex-pet.limit-aura.plist"
LOG="$TEST_HOME/Library/Logs/CodexPetLimitRings.log"
ERROR_LOG="$TEST_HOME/Library/Logs/CodexPetLimitRings.err.log"
PREFERENCES="$TEST_HOME/Library/Preferences/local.codex.pet-limit-rings.plist"
OLD_PREFERENCES="$TEST_HOME/Library/Preferences/local.codex.limit-aura.plist"
STATE_CACHE="$TEST_CODEX_HOME/codex-pet-limit-rings/limit-state-cache.json"
DEFAULTS_DOMAIN="$DEFAULTS_STATE/local.codex.pet-limit-rings"

mkdir -p \
  "$APP/Contents/MacOS" "$OLD_APP/Contents/MacOS" \
  "$(dirname "$AGENT")" "$(dirname "$LOG")" "$(dirname "$PREFERENCES")" \
  "$(dirname "$STATE_CACHE")" "$DEFAULTS_DOMAIN"
touch \
  "$APP/Contents/MacOS/CodexPetLimitRings" "$OLD_APP/Contents/MacOS/CodexLimitAura" \
  "$AGENT" "$OLD_AGENT" "$LOG" "$ERROR_LOG" "$PREFERENCES" "$OLD_PREFERENCES" \
  "$STATE_CACHE" "$PROCESS_STATE/CodexPetLimitRings" "$DEFAULTS_DOMAIN/unrelated-key" \
  "$TEST_CODEX_HOME/.codex-global-state.json" "$TEST_HOME/Library/Logs/unrelated.log"

OUTPUT="$({
  HOME="$TEST_HOME" CODEX_HOME="$TEST_CODEX_HOME" \
    CODEX_PET_LIMIT_RINGS_APP= CODEX_LIMIT_AURA_APP= TEST_KILL_FAIL=0 \
    PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT/tools/uninstall-limit-rings.sh"
} 2>&1)"

for path in \
  "$APP" "$OLD_APP" "$AGENT" "$OLD_AGENT" "$LOG" "$ERROR_LOG" \
  "$PREFERENCES" "$OLD_PREFERENCES" "$STATE_CACHE" \
  "$PROCESS_STATE/CodexPetLimitRings" "$DEFAULTS_DOMAIN"
do
  [[ ! -e "$path" ]] || { echo "uninstall artifact remains: $path" >&2; exit 1; }
done
for path in "$TEST_CODEX_HOME/.codex-global-state.json" "$TEST_HOME/Library/Logs/unrelated.log"; do
  [[ -e "$path" ]] || { echo "unrelated state removed: $path" >&2; exit 1; }
done
grep -Fq "Codex Pet Limit Rings uninstalled" <<<"$OUTPUT"
grep -Fq "bootout gui/$(id -u)/com.codex-pet.limit-rings" "$LAUNCH_LOG"

mkdir -p "$APP/Contents/MacOS"
touch "$APP/Contents/MacOS/CodexPetLimitRings" "$PROCESS_STATE/CodexPetLimitRings"
set +e
FAIL_OUTPUT="$({
  HOME="$TEST_HOME" CODEX_HOME="$TEST_CODEX_HOME" TEST_KILL_FAIL=1 \
    CODEX_PET_LIMIT_RINGS_APP= CODEX_LIMIT_AURA_APP= \
    PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT/tools/uninstall-limit-rings.sh"
} 2>&1)"
FAIL_STATUS=$?
set -e

[[ "$FAIL_STATUS" -ne 0 ]] || { echo "uninstall succeeded with a live process" >&2; exit 1; }
! grep -Fq "Codex Pet Limit Rings uninstalled" <<<"$FAIL_OUTPUT" || {
  echo "uninstall printed success with a live process" >&2
  exit 1
}
[[ -e "$APP" ]] || { echo "app removed before its process stopped" >&2; exit 1; }

echo "limit rings uninstall tests passed"
