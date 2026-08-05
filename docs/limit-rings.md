# Codex Pet Limit Rings

Codex Pet Limit Rings is a native macOS companion app for Codex pets. It does not patch Codex, replace pet art, or modify the Codex app bundle. It follows the current pet with a transparent always-on-top window and exposes its own menu-bar icon.

The usage overlay is pet-agnostic. It works with any pet Codex displays because the app tracks the pet window bounds rather than reading, editing, or understanding the pet artwork.

## Experience Contract

- A usage-overlay icon appears in the macOS menu bar.
- `Show Usage Overlay` toggles the overlay without quitting the app.
- `Refresh Now` rereads usage and pet-position state.
- `Display Style` switches between the default rings and compact bars.
- `Position`은 링과 바 모두에서 표시되며, 각 스타일의 위치를 독립적으로 저장합니다. 바 스타일에서는 `Bar Width`도 함께 표시됩니다.
- `Bar Width`는 바 스타일에서만 표시되며 짧게, 보통, 넓게 중 하나를 선택합니다.
- The menu summary includes the source and age of the current rate-limit snapshot.
- A transient app-server failure keeps the last successful snapshot for up to 30 minutes while its reset window remains current; the menu labels this source `Cached`.
- Expired rate-limit events are treated as unavailable instead of being shown as current usage.
- When no current rate-limit event is available, the overlay shows compact `NO DATA` text instead of stale percentages.
- In bar style, two compact bars below the pet show short-window and weekly remaining capacity.
- In bar style, percentages and reset countdowns are shown beside the bars.
- 링 스타일의 기본 위치는 펫 중앙이며, 이동 후에도 같은 짧은 사용량 창·주간 값을 아래쪽 고정 반투명 배지 두 개에 표시합니다.
- Dragging the pet makes the overlay follow the gesture immediately while Codex persists the new position when mouse monitoring is enabled.
- Closing the Codex pet hides the overlay.
- Multi-display positioning uses the screen containing the pet bounds, not the currently focused screen.
- macOS desktop/Space switching keeps the overlay visible with the pet rather than tying it to one active desktop.
- Switching to another Codex pet requires no extra setup; the overlay follows the active pet.

## Data Flow

The app reads the current Codex rate-limit snapshot first, then falls back to local Codex files:

- Codex CLI `app-server --stdio`: current account limit snapshot via `account/rateLimits/read`. The app checks explicit environment overrides, Codex app-bundle paths, and standard Homebrew paths. The `codex` limit is rendered as the main short-window and weekly rings; other limit ids are shown as additional model dots.
- `~/.codex/.codex-global-state.json`: 현재 팻 위치. 명시적 `anchor`, 기존 `width`/`height`/`mascot`, `x`/`y`만 저장하는 anchor-only 형식을 순서대로 읽습니다. 크기가 없는 형식에는 기존 상세 bounds와 실제 렌더에서 확인한 팻 크기 `80x87`을 사용합니다.
- `electron-avatar-overlay-open` in the same state file: whether the Codex pet is currently open.
- `~/.codex/sqlite/logs_2.sqlite` 또는 legacy `~/.codex/logs_2.sqlite`: 만료되지 않은 최신 websocket `codex.rate_limits` 이벤트의 fallback 소스입니다.

For rate limits, the fallback order is app-server, a current SQLite `codex.rate_limits` event, then the last successful app-server snapshot when it is no older than 30 minutes and its reset window is still current. Only then does the overlay show `NO DATA`.

The app watches `~/.codex/.codex-global-state.json` with a macOS file event source, so pet open/close and position writes trigger an immediate frame update. A slow frame timer remains as a fallback in case the file is replaced or an event is missed.

No OpenAI API key is required. The app does not read `~/.codex/auth.json` and does not call an OpenAI endpoint directly; the Codex app-server returns the account snapshot using Codex's own auth state. The menu summary says `Codex` for app-server values and `Local` when it is showing the local event-log fallback.
Use `--no-mouse-monitor` to disable global mouse event monitoring; this disables drag-follow while the usage overlay remains visible. The helper scripts apply that mode when `CODEX_PET_LIMIT_RINGS_NO_MOUSE_MONITOR=1` is set.

## Rendering Model

- Ring style is the default and draws short-window and weekly remaining capacity around the pet with fixed lower translucent readouts.
- Bar style draws the short-window remaining percentage and reset countdown in the top bar.
- Bar style draws the weekly remaining percentage and reset countdown in the bottom bar.
- 주간 값이 없더라도 short-window 바는 첫 번째 슬롯 위치를 유지합니다.
- Colors are derived from remaining capacity: green/blue for healthy, amber for low, red for critical.
- Bar outlines stay visible, and a short moving gradient sweep appears on each bar after local usage-log checks, which normally run every 20 seconds.
- Ring style uses the same color model and is drawn around the pet with fixed lower translucent readouts.
- The overlay is drawn with no panel background, so only the bars/rings and text are visible.
- 메뉴에서 선택한 표시 스타일, 링·바의 개별 위치 오프셋, 바 너비는 `UserDefaults`에 저장됩니다.


See `docs/solutions/workflow-issues/usage-overlay-no-data-diagnosis.md` for the evidence-first diagnosis sequence after a Codex update.

## Install Contract

`tools/install-limit-rings.sh` builds:

```text
~/Applications/CodexPetLimitRings.app
```

and installs:

```text
~/Library/LaunchAgents/com.codex-pet.limit-rings.plist
```

The LaunchAgent starts the app at login. The installer also removes the earlier prototype app and LaunchAgent names if present:

```text
~/Applications/CodexLimitAura.app
~/Library/LaunchAgents/com.codex-pet.limit-aura.plist
```

`tools/uninstall-limit-rings.sh`는 LaunchAgent와 설치된 프로세스를 종료하고 앱 번들, 앱 로그, 전용 preferences, 이전 릴리스의 hook 설정과 로컬 상태를 제거합니다. 서비스나 프로세스가 남으면 성공 메시지 대신 nonzero로 종료합니다.

Codex 펫 자체와 저장소 `tmp/`의 개발 산출물은 제거하지 않습니다.

The build, install, and uninstall scripts refuse destructive app-bundle operations outside the repository `tmp/` app path or the default `~/Applications/CodexPetLimitRings.app` and `~/Applications/CodexLimitAura.app` paths.

## Development

Build and run the app from the repository:

```bash
tools/run-limit-rings.sh
```

Render a static preview:

```bash
swiftc tools/codex-pet-limit-rings.swift -o tmp/codex-pet-limit-rings -framework AppKit -lsqlite3
tmp/codex-pet-limit-rings --preview tmp/limit-rings-preview.png --size 164
tools/test-cleanup-legacy-turn-usage.sh
tools/test-uninstall-limit-rings.sh
```

## Codex Skill

The repository includes a skill at `skills/codex-pet-limit-rings/`. Copy that folder into `~/.codex/skills/` or run `tools/install-codex-skill.sh` to make Codex auto-discover the workflow in future sessions.

The skill intentionally points agents at the companion-app boundary and validation commands. It should not encourage app-bundle patching as the default path.
