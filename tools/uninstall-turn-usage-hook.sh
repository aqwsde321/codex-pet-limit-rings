#!/usr/bin/env bash
set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
HOOK_SCRIPT="$CODEX_HOME/codex-pet-limit-rings/hooks/codex-turn-usage-stop-hook.py"

/usr/bin/python3 - "$CODEX_HOME" "$HOOK_SCRIPT" <<'PY'
import fcntl
import json
import shutil
import sys
import time
from pathlib import Path


codex_home = Path(sys.argv[1]).expanduser()
hook_script = Path(sys.argv[2]).expanduser().resolve()
hooks_path = codex_home / "hooks.json"
timestamp = time.strftime("%Y%m%d%H%M%S")
config_path = codex_home / "config.toml"
install_state_path = codex_home / "codex-pet-limit-rings" / "install-state.json"
settings_path = codex_home / "codex-pet-limit-rings" / "settings.json"
worker_lock_path = codex_home / "codex-pet-limit-rings" / "turn-usage-worker.lock"
lifecycle_lock_path = codex_home / "codex-pet-limit-rings" / "turn-usage-lifecycle.lock"
cleanup_paths = [
    codex_home / "codex-pet-limit-rings" / "turn-usage.json",
    codex_home / "codex-pet-limit-rings" / "turn-usage-ledger.json",
    codex_home / "codex-pet-limit-rings" / "turn-usage-summary.json",
    settings_path,
    codex_home / "codex-pet-limit-rings" / "turn-usage.json.tmp",
    codex_home / "codex-pet-limit-rings" / "turn-usage-ledger.json.tmp",
    codex_home / "codex-pet-limit-rings" / "turn-usage-summary.json.tmp",
    codex_home / "codex-pet-limit-rings" / "turn-usage.lock",
    codex_home / "codex-pet-limit-rings" / "turn-usage-hook.log",
    codex_home / "codex-pet-limit-rings" / "turn-usage-hook.log.1",
    codex_home / "codex-pet-limit-rings" / "turn-usage-queue.jsonl",
    codex_home / "codex-pet-limit-rings" / "turn-usage-queue.jsonl.tmp",
]
block_begin = "# Codex Pet Limit Rings turn-usage hook: begin\n"
block_end = "# Codex Pet Limit Rings turn-usage hook: end\n"


def is_hook_marker(line):
    stripped = line.strip()
    return stripped == block_begin.strip() or stripped == block_end.strip()


def is_our_hook_command(line):
    return toml_key(line) == "command" and str(hook_script) in line


def remove_existing_inline_stop_hooks(text):
    lines = text.splitlines(keepends=True)
    filtered = []
    index = 0
    while index < len(lines):
        if is_hook_marker(lines[index]):
            index += 1
            continue

        header = toml_header_name(lines[index])
        if header == "hooks.Stop":
            end = index + 1
            while end < len(lines):
                next_header = toml_header_name(lines[end])
                if next_header is not None and next_header != "hooks.Stop.hooks":
                    break
                end += 1
            if any(is_our_hook_command(line) for line in lines[index:end]):
                index = end
                continue

        filtered.append(lines[index])
        index += 1

    return "".join(filtered)


def read_install_state():
    try:
        with install_state_path.open("r", encoding="utf-8") as handle:
            state = json.load(handle)
            return state if isinstance(state, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def write_install_state(state):
    if state:
        install_state_path.parent.mkdir(parents=True, exist_ok=True)
        with install_state_path.open("w", encoding="utf-8") as handle:
            json.dump(state, handle, indent=2, sort_keys=True)
            handle.write("\n")
    else:
        install_state_path.unlink(missing_ok=True)


def find_features_block(lines):
    features_start = None
    features_end = len(lines)
    for index, line in enumerate(lines):
        header = toml_header_name(line)
        if header == "features":
            features_start = index
            continue
        if features_start is not None and index > features_start and header is not None:
            features_end = index
            break
    return features_start, features_end


def toml_header_name(line):
    stripped = line.strip()
    if stripped.startswith("[["):
        end = stripped.find("]]")
        return stripped[2:end].strip() if end >= 0 else None
    if stripped.startswith("["):
        end = stripped.find("]")
        return stripped[1:end].strip() if end >= 0 else None
    return None


def toml_key(line):
    if "=" not in line:
        return ""
    key, value = line.split("=", 1)
    return key.strip()


def has_inline_hook_sections(text):
    for line in text.splitlines():
        header = toml_header_name(line)
        if header == "hooks" or (header or "").startswith("hooks."):
            return True
    return False


def restore_codex_hooks_setting(text):
    install_state = read_install_state()
    hook_state = install_state.get("codex_hooks")
    if not isinstance(hook_state, dict):
        return text

    keep_enabled_for_other_hooks = has_inline_hook_sections(text) and hook_state.get("inline_hooks_existed") is not True
    lines = text.splitlines(keepends=True)
    features_start, features_end = find_features_block(lines)
    if features_start is not None:
        setting_index = None
        for index in range(features_start + 1, features_end):
            if toml_key(lines[index]) == "codex_hooks":
                setting_index = index
                break

        previous_line = hook_state.get("previous_line")
        if setting_index is not None:
            if keep_enabled_for_other_hooks:
                lines[setting_index] = "codex_hooks = true\n"
            elif previous_line is None:
                del lines[setting_index]
            else:
                lines[setting_index] = previous_line + "\n"

        if hook_state.get("features_existed") is False:
            features_start, features_end = find_features_block(lines)
            if features_start is not None:
                feature_body = lines[features_start + 1:features_end]
                if all(not line.strip() for line in feature_body):
                    del lines[features_start:features_end]

    install_state.pop("codex_hooks", None)
    write_install_state(install_state)
    return "".join(lines)


def with_lifecycle_lock(callback):
    lifecycle_lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lifecycle_lock_path.open("a+", encoding="utf-8") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        callback()


def disable_turn_usage():
    settings_path.unlink(missing_ok=True)


def wait_for_worker_idle():
    worker_lock_path.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + 6.0
    with worker_lock_path.open("a+", encoding="utf-8") as lock_file:
        while True:
            try:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                return
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    return
                time.sleep(0.1)


def cleanup_local_state():
    for path in cleanup_paths:
        path.unlink(missing_ok=True)


if config_path.exists():
    original = config_path.read_text(encoding="utf-8")
    updated = restore_codex_hooks_setting(remove_existing_inline_stop_hooks(original))
    if updated != original:
        shutil.copy2(config_path, config_path.with_name(f"{config_path.name}.bak.{timestamp}"))
        config_path.write_text(updated, encoding="utf-8")

data = None
if hooks_path.exists():
    try:
        with hooks_path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (json.JSONDecodeError, OSError) as error:
        print(f"warning: skipping legacy hooks.json cleanup: {error}", file=sys.stderr)
    if data is not None and not isinstance(data, dict):
        print("warning: skipping legacy hooks.json cleanup: root is not an object", file=sys.stderr)
        data = None

if data is not None:
    changed = False
    hooks = data.get("hooks") or {}
    if not isinstance(hooks, dict):
        hooks = {}
    stop_groups = hooks.get("Stop") or []
    if not isinstance(stop_groups, list):
        stop_groups = []
    filtered_groups = []
    hook_script_text = str(hook_script)
    for stop_group in stop_groups:
        if not isinstance(stop_group, dict):
            filtered_groups.append(stop_group)
            continue
        group_hooks = stop_group.get("hooks") or []
        if not isinstance(group_hooks, list):
            filtered_groups.append(stop_group)
            continue
        filtered_hooks = [
            item for item in group_hooks
            if not isinstance(item, dict)
            or not isinstance(item.get("command"), str)
            or hook_script_text not in item.get("command")
        ]
        if len(filtered_hooks) != len(group_hooks):
            changed = True
        if filtered_hooks:
            stop_group["hooks"] = filtered_hooks
            filtered_groups.append(stop_group)

    if changed:
        if filtered_groups:
            hooks["Stop"] = filtered_groups
        else:
            hooks.pop("Stop", None)
        data["hooks"] = hooks
        shutil.copy2(hooks_path, hooks_path.with_name(f"{hooks_path.name}.bak.{timestamp}"))
        with hooks_path.open("w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")

with_lifecycle_lock(disable_turn_usage)
wait_for_worker_idle()
with_lifecycle_lock(cleanup_local_state)
PY

rm -f "$HOOK_SCRIPT"

echo "Codex turn-usage Stop hook uninstalled"
echo "Restart Codex sessions for hook config changes to take effect"
