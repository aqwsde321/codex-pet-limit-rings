---
name: codex-pet-limit-rings
description: Install, run, customize, package, or debug the Codex Pet Limit Rings macOS companion app for Codex pets. Use when the user asks for Codex pet usage-limit bars or rings, a menu-bar toggle, launch-at-login packaging, live/cached Codex limit visualization, or open-source distribution of the pet usage overlay.
---

# Codex Pet Limit Rings

## Core Rule

Keep the Codex desktop app unpatched by default. Ship and modify the usage overlay as a companion macOS app that reads local Codex state and exposes its own menu-bar icon. Only discuss direct Codex app menu patching as a brittle optional route, because it requires `app.asar` patching, Electron integrity updates, and re-signing after Codex updates.

The rings are pet-agnostic. Do not add pet-specific setup unless a user explicitly asks for a custom visual treatment; by default the overlay follows whatever Codex pet is currently active.

## Locate The Project

If this skill is bundled in the repository, the project root is two directories above this `SKILL.md`. Otherwise find or ask for a checkout containing:

```text
tools/codex-pet-limit-rings.swift
tools/install-limit-rings.sh
tools/run-limit-rings.sh
```

Use that checkout as the working directory. Read `AGENTS.md` first if it exists.

## Common Tasks

Install or enable the usage overlay for a user:

```bash
tools/install-limit-rings.sh
```

Install the optional Codex `Stop` hook for finalized turn-usage tracking:

```bash
tools/install-turn-usage-hook.sh
```

Run a development build without installing a login item:

```bash
tools/run-limit-rings.sh
```

Uninstall:

```bash
tools/uninstall-limit-rings.sh
```

Remove only the optional turn-usage hook:

```bash
tools/uninstall-turn-usage-hook.sh
```

Install this skill into local Codex:

```bash
tools/install-codex-skill.sh
```

Verify the live app:

```bash
pgrep -fl CodexPetLimitRings
launchctl print "gui/$(id -u)/com.codex-pet.limit-rings" >/dev/null
```

## Data Contract

The rings read:

- `~/.codex/.codex-global-state.json` for `electron-avatar-overlay-open` and `electron-avatar-overlay-bounds.mascot`.
- `~/.codex/logs_2.sqlite` for the newest local websocket `codex.rate_limits` event and recent response `usage` token counters from `target = 'codex_api::endpoint::responses_websocket'`.
- `~/.codex/codex-pet-limit-rings/settings.json` for the app-written `Track Turn Usage` setting. The optional hook should no-op when this setting is off or missing.
- `~/.codex/codex-pet-limit-rings/turn-usage-queue.jsonl` when the optional `Stop` hook is installed. This bounded queue should contain only ids, enqueue timestamps, and retry counters, and the hook should return immediately after enqueueing.
- `~/.codex/codex-pet-limit-rings/turn-usage.json` when the optional `Stop` hook is installed. This compact state file should contain only ids, response ids when present, timestamps, call counts, and token counters, not prompt or tool-output text.

The app should not read `~/.codex/auth.json` or call a remote usage endpoint. The top usage bar or outer ring is the short-window remaining percentage. The bottom usage bar or inner ring is the weekly remaining percentage. The menu summary should say `Local` and include the local log age when the local log value is active. The menu can show recent per-thread usage token counts and the latest limit delta, and the overlay can show a short toast for newly observed turn usage. Display style, position offsets, and bar-width presets are controlled from the menu and persisted in `UserDefaults`.

Pet wakeups and moves are driven by a filesystem watcher on `~/.codex/.codex-global-state.json`, with a slow fallback timer for missed events. Keep that event-driven path intact when changing frame-following behavior.
Use `--no-mouse-monitor` when the user wants no global mouse event monitoring; this disables drag-follow while the usage overlay remains visible. Set `CODEX_PET_LIMIT_RINGS_NO_MOUSE_MONITOR=1` for helper-script launches or installs.

## Editing Workflow

When changing behavior or visuals:

1. Edit `tools/codex-pet-limit-rings.swift`.
2. Keep packaging scripts in `tools/` and update `docs/limit-rings.md` when the user-facing contract changes.
3. Run:

```bash
bash -n tools/*.sh
swiftc tools/codex-pet-limit-rings.swift -o tmp/codex-pet-limit-rings -framework AppKit -lsqlite3
tmp/codex-pet-limit-rings --preview tmp/limit-rings-preview.png --size 164
```

4. Relaunch with `tools/run-limit-rings.sh` for development or `tools/install-limit-rings.sh` for the packaged login-item flow.

## Open-Source Hygiene

Keep the app privacy-preserving, source-buildable, and uninstallable. Do not commit local `tmp/` builds, logs, derived pet spritesheets, or user-specific Codex data. Preserve the MIT license and document any new local files or permissions in `docs/limit-rings.md`.
