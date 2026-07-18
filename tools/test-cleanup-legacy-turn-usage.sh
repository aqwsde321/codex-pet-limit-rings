#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-pet-legacy-cleanup.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

CODEX_HOME="$TEST_ROOT/.codex"
STATE_DIR="$CODEX_HOME/codex-pet-limit-rings"
HOOK_SCRIPT="$STATE_DIR/hooks/codex-turn-usage-stop-hook.py"
mkdir -p "$(dirname "$HOOK_SCRIPT")"
touch "$HOOK_SCRIPT" "$STATE_DIR/turn-usage.json" "$STATE_DIR/turn-usage-hook.log"

cat > "$CODEX_HOME/config.toml" <<EOF
[features]
hooks = true

[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = ["/usr/bin/other-hook"]

# Codex Pet Limit Rings turn-usage hook: begin
[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = ["$HOOK_SCRIPT"]
# Codex Pet Limit Rings turn-usage hook: end
EOF

CODEX_HOME="$CODEX_HOME" "$ROOT/tools/cleanup-legacy-turn-usage.sh" >/dev/null

grep -Fq '/usr/bin/other-hook' "$CODEX_HOME/config.toml"
if grep -Fq 'codex-turn-usage-stop-hook.py' "$CODEX_HOME/config.toml"; then
  echo "legacy hook command remains" >&2
  exit 1
fi
if [[ -e "$HOOK_SCRIPT" || -e "$STATE_DIR/turn-usage.json" || -e "$STATE_DIR/turn-usage-hook.log" ]]; then
  echo "legacy hook state remains" >&2
  exit 1
fi

CODEX_HOME="$CODEX_HOME" "$ROOT/tools/cleanup-legacy-turn-usage.sh" >/dev/null

SECOND_HOME="$TEST_ROOT/second/.codex"
SECOND_STATE="$SECOND_HOME/codex-pet-limit-rings"
SECOND_HOOK="$SECOND_STATE/hooks/codex-turn-usage-stop-hook.py"
mkdir -p "$(dirname "$SECOND_HOOK")"
touch "$SECOND_HOOK"
cat > "$SECOND_STATE/install-state.json" <<'EOF'
{
  "hooks": {
    "features_existed": true,
    "inline_hooks_existed": false,
    "previous_line": "hooks = false"
  }
}
EOF
cat > "$SECOND_HOME/config.toml" <<EOF
[features]
hooks = true

[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = ["$SECOND_HOOK"]
EOF

CODEX_HOME="$SECOND_HOME" "$ROOT/tools/cleanup-legacy-turn-usage.sh" >/dev/null
grep -Fq 'hooks = false' "$SECOND_HOME/config.toml"
if grep -Fq '[[hooks.Stop]]' "$SECOND_HOME/config.toml"; then
  echo "legacy-only Stop hook remains" >&2
  exit 1
fi

THIRD_HOME="$TEST_ROOT/third/.codex"
THIRD_STATE="$THIRD_HOME/codex-pet-limit-rings"
mkdir -p "$THIRD_STATE"
touch "$THIRD_STATE/turn-usage-queue.lock"
CODEX_HOME="$THIRD_HOME" "$ROOT/tools/cleanup-legacy-turn-usage.sh" >/dev/null
if [[ -e "$THIRD_STATE/turn-usage-queue.lock" ]]; then
  echo "legacy queue lock remains" >&2
  exit 1
fi

echo "legacy turn-usage cleanup tests passed"
