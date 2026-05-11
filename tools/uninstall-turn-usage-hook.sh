#!/usr/bin/env bash
set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
HOOK_SCRIPT="$CODEX_HOME/codex-pet-limit-rings/hooks/codex-turn-usage-stop-hook.py"
STATE_FILE="$CODEX_HOME/codex-pet-limit-rings/turn-usage.json"
LOCK_FILE="${STATE_FILE%.json}.lock"
LOG_FILE="$CODEX_HOME/codex-pet-limit-rings/turn-usage-hook.log"

/usr/bin/python3 - "$CODEX_HOME" "$HOOK_SCRIPT" <<'PY'
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
block_begin = "# Codex Pet Limit Rings turn-usage hook: begin\n"
block_end = "# Codex Pet Limit Rings turn-usage hook: end\n"


def remove_marked_block(text):
    start = text.find(block_begin)
    if start < 0:
        return text
    end = text.find(block_end, start)
    if end < 0:
        return text
    end += len(block_end)
    if end < len(text) and text[end] == "\n":
        end += 1
    return text[:start] + text[end:]


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


if config_path.exists():
    original = config_path.read_text(encoding="utf-8")
    updated = restore_codex_hooks_setting(remove_marked_block(original))
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
PY

rm -f "$HOOK_SCRIPT"
rm -f "$STATE_FILE" "$LOCK_FILE" "$LOG_FILE" "$LOG_FILE.1"

echo "Codex turn-usage Stop hook uninstalled"
echo "Restart Codex sessions for hook config changes to take effect"
