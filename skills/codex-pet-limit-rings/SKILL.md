---
name: codex-pet-limit-rings
description: Install, run, customize, package, or debug the Codex Pet Limit Rings macOS companion app for Codex pets. Use when the user asks for Codex pet usage-limit bars or rings, a menu-bar toggle, launch-at-login packaging, live/cached Codex limit visualization, overlay NO DATA or missing usage after a Codex update, or open-source distribution of the pet usage overlay.
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

When a user asks to install or set this up, recommend the smallest useful setup first:

- Default recommendation: install only the overlay app.
- Ask before installing this skill into local Codex. Enable it only when the user wants to reuse this workflow from other Codex conversations.

Install or enable the usage overlay for a user:

```bash
tools/install-limit-rings.sh
```

Install without requiring the user to clone this repository:

```bash
curl -fsSL https://raw.githubusercontent.com/aqwsde321/codex-pet-limit-rings/main/tools/install-remote.sh | bash
```

Run a development build without installing a login item:

```bash
tools/run-limit-rings.sh
```

Uninstall:

```bash
tools/uninstall-limit-rings.sh
```

Uninstall without requiring a clone:

```bash
curl -fsSL https://raw.githubusercontent.com/aqwsde321/codex-pet-limit-rings/main/tools/install-remote.sh | bash -s -- --uninstall
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

## 업데이트 회귀 진단

Codex 업데이트 후 오버레이가 `NO DATA`를 표시하면 설치된 바이너리를 먼저 확인합니다. 다음으로 `codex app-server --stdio`의 `account/rateLimits/read`와 활성 SQLite 로그의 최신 `codex.rate_limits` 행을 각각 검증하고, 실패한 경로만 수정합니다. 저장소 작업에서는 `docs/solutions/workflow-issues/usage-overlay-no-data-diagnosis.md`를 참고합니다.

## Data Contract

The rings read:

- Codex CLI `app-server --stdio` for the current `account/rateLimits/read` snapshot. Resolve explicit environment overrides, Codex app-bundle paths, and standard Homebrew paths because LaunchAgent PATH may omit Homebrew.
- `~/.codex/.codex-global-state.json` for `electron-avatar-overlay-open` and `electron-avatar-overlay-bounds.mascot`.
- `~/.codex/sqlite/logs_2.sqlite` 또는 legacy `~/.codex/logs_2.sqlite`에서 최신 로컬 websocket `codex.rate_limits` fallback을 읽습니다.


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
tools/test-cleanup-legacy-turn-usage.sh
```

4. Relaunch with `tools/run-limit-rings.sh` for development or `tools/install-limit-rings.sh` for the packaged login-item flow.

## Open-Source Hygiene

Keep the app privacy-preserving, source-buildable, and uninstallable. Do not commit local `tmp/` builds, logs, derived pet spritesheets, or user-specific Codex data. Preserve the MIT license and document any new local files or permissions in `docs/limit-rings.md`.
