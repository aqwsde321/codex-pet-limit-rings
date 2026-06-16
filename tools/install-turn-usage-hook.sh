#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
HOOK_HOME="$CODEX_HOME/codex-pet-limit-rings/hooks"
HOOK_SCRIPT="$HOOK_HOME/codex-turn-usage-stop-hook.py"

mkdir -p "$HOOK_HOME"
install -m 700 "$ROOT/tools/codex-turn-usage-stop-hook.py" "$HOOK_SCRIPT"

/usr/bin/python3 - "$CODEX_HOME" "$HOOK_SCRIPT" <<'PY'
import json
import shlex
import shutil
import sys
import time
from pathlib import Path


codex_home = Path(sys.argv[1]).expanduser()
hook_script = Path(sys.argv[2]).expanduser().resolve()
config_path = codex_home / "config.toml"
hooks_path = codex_home / "hooks.json"
install_state_path = codex_home / "codex-pet-limit-rings" / "install-state.json"
timestamp = time.strftime("%Y%m%d%H%M%S")
block_begin = "# Codex Pet Limit Rings turn-usage hook: begin\n"
block_end = "# Codex Pet Limit Rings turn-usage hook: end\n"


def backup(path):
    if path.exists():
        backup_path = path.with_name(f"{path.name}.bak.{timestamp}")
        if not backup_path.exists():
            shutil.copy2(path, backup_path)


def read_install_state():
    try:
        with install_state_path.open("r", encoding="utf-8") as handle:
            state = json.load(handle)
            return state if isinstance(state, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def write_install_state(state):
    install_state_path.parent.mkdir(parents=True, exist_ok=True)
    with install_state_path.open("w", encoding="utf-8") as handle:
        json.dump(state, handle, indent=2, sort_keys=True)
        handle.write("\n")


def is_true_setting(line, key="hooks"):
    return toml_key(line) == key and toml_value(line).lower() == "true"


def toml_key(line):
    if "=" not in line:
        return ""
    key, value = line.split("=", 1)
    return key.strip()


def toml_value(line):
    if "=" not in line:
        return ""
    key, value = line.split("=", 1)
    return value.strip()


def toml_header_name(line):
    stripped = line.strip()
    if stripped.startswith("[["):
        end = stripped.find("]]")
        return stripped[2:end].strip() if end >= 0 else None
    if stripped.startswith("["):
        end = stripped.find("]")
        return stripped[1:end].strip() if end >= 0 else None
    return None


def has_inline_hook_sections(text):
    for line in text.splitlines():
        header = toml_header_name(line)
        if header == "hooks" or (header or "").startswith("hooks."):
            return True
    return False


def canonical_hooks_line(line):
    return f"hooks = {toml_value(line)}"


def ensure_hooks_feature():
    config_path.parent.mkdir(parents=True, exist_ok=True)
    original = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
    lines = original.splitlines(keepends=True)
    changed = False
    feature_state_changed = False

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

    features_existed = features_start is not None
    if features_start is None:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        if lines and lines[-1].strip():
            lines.append("\n")
        lines.extend(["[features]\n", "hooks = true\n"])
        changed = True
        feature_state_changed = True
        previous_line = None
    else:
        setting_index = None
        legacy_setting_indices = []
        for index in range(features_start + 1, features_end):
            key = toml_key(lines[index])
            if key == "hooks":
                setting_index = index
            elif key == "codex_hooks":
                legacy_setting_indices.append(index)
        if setting_index is None:
            if legacy_setting_indices:
                setting_index = legacy_setting_indices[0]
                previous_line = canonical_hooks_line(lines[setting_index])
                lines[setting_index] = "hooks = true\n"
                changed = True
                feature_state_changed = not is_true_setting(previous_line)
                legacy_setting_indices = legacy_setting_indices[1:]
            else:
                lines.insert(features_end, "hooks = true\n")
                changed = True
                feature_state_changed = True
                previous_line = None
        elif not is_true_setting(lines[setting_index]):
            previous_line = lines[setting_index].rstrip("\n")
            lines[setting_index] = "hooks = true\n"
            changed = True
            feature_state_changed = True
        else:
            previous_line = None

        for index in reversed(legacy_setting_indices):
            del lines[index]
            changed = True

    updated = "".join(lines)
    if changed and updated != original:
        if feature_state_changed:
            install_state = read_install_state()
            install_state.setdefault("hooks", {
                "features_existed": features_existed,
                "inline_hooks_existed": has_inline_hook_sections(original),
                "previous_line": previous_line,
            })
            write_install_state(install_state)
        backup(config_path)
        config_path.write_text(updated, encoding="utf-8")


def hook_command():
    command = f"/usr/bin/python3 {shlex.quote(str(hook_script))}"
    return command


def is_hook_marker(line):
    stripped = line.strip()
    return stripped == block_begin.strip() or stripped == block_end.strip()


def is_our_hook_command(line):
    return toml_key(line) == "command" and str(hook_script) in toml_value(line)


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


def ensure_inline_stop_hook():
    config_path.parent.mkdir(parents=True, exist_ok=True)
    original = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
    without_old = remove_existing_inline_stop_hooks(original)
    block = (
        "\n"
        f"{block_begin}"
        "[[hooks.Stop]]\n"
        "[[hooks.Stop.hooks]]\n"
        'type = "command"\n'
        f"command = {json.dumps(hook_command())}\n"
        "timeout = 10\n"
        'statusMessage = "Recording turn usage"\n'
        f"{block_end}"
    )
    if without_old and not without_old.endswith("\n"):
        without_old += "\n"
    updated = without_old + block
    if updated != original:
        backup(config_path)
        config_path.write_text(updated, encoding="utf-8")


def remove_legacy_json_hook():
    if not hooks_path.exists():
        return

    try:
        with hooks_path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (json.JSONDecodeError, OSError) as error:
        print(f"warning: skipping legacy hooks.json cleanup: {error}", file=sys.stderr)
        return
    if not isinstance(data, dict):
        print("warning: skipping legacy hooks.json cleanup: root is not an object", file=sys.stderr)
        return

    command = hook_command()
    filtered = []
    changed = False
    hooks = data.get("hooks") or {}
    if not isinstance(hooks, dict):
        return
    for stop_group in hooks.get("Stop") or []:
        if not isinstance(stop_group, dict):
            filtered.append(stop_group)
            continue
        group_hooks = stop_group.get("hooks") or []
        if not isinstance(group_hooks, list):
            filtered.append(stop_group)
            continue
        group_hooks = [
            item for item in group_hooks
            if not isinstance(item, dict)
            or not isinstance(item.get("command"), str)
            or (item.get("command") != command and str(hook_script) not in item.get("command"))
        ]
        if len(group_hooks) != len(stop_group.get("hooks") or []):
            changed = True
        if group_hooks:
            stop_group["hooks"] = group_hooks
            filtered.append(stop_group)

    if not changed:
        return

    if filtered:
        hooks["Stop"] = filtered
    else:
        hooks.pop("Stop", None)
    data["hooks"] = hooks
    backup(hooks_path)
    with hooks_path.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")


ensure_hooks_feature()
ensure_inline_stop_hook()
remove_legacy_json_hook()
PY

echo "Codex turn-usage Stop hook installed"
echo "Hook script: $HOOK_SCRIPT"
echo "Hook config: $CODEX_HOME/config.toml"
echo "Restart Codex sessions for hook config changes to take effect"
