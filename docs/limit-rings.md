# Codex Pet Limit Rings

Codex Pet Limit Rings is a native macOS companion app for Codex pets. It does not patch Codex, replace pet art, or modify the Codex app bundle. It follows the current pet with a transparent always-on-top window and exposes its own menu-bar icon.

The usage overlay is pet-agnostic. It works with any pet Codex displays because the app tracks the pet window bounds rather than reading, editing, or understanding the pet artwork.

## Experience Contract

- A usage-overlay icon appears in the macOS menu bar.
- `Track Turn Usage` defaults to off and toggles local turn-usage log reads, the recent-turn menu section, and turn-usage toasts.
- `Show Usage Overlay` toggles the overlay without quitting the app.
- `Refresh Now` rereads usage and pet-position state.
- `Display Style` switches between the default rings and compact bars.
- In bar style, bar-only layout controls appear under `Display Style`; `Bar Width` is shown first, followed by an indented `Position` control.
- In bar style, `Position` uses an inline menu control so position buttons can be clicked repeatedly without reopening the menu. It moves only the bar readouts; turn-usage toasts stay anchored near the pet like ring-style toasts.
- In bar style, `Bar Width` switches between short, normal, and wide bars. Bar-only controls are hidden in ring style.
- The menu summary includes how old the local rate-limit log entry is.
- When `Track Turn Usage` is enabled, the menu shows compact color-coded usage-token counts for up to three recent turn groups.
- When `Track Turn Usage` is enabled, the menu shows the latest short-window and weekly limit delta from consecutive rate-limit events.
- When `Track Turn Usage` is enabled, a short toast appears near the overlay when a new turn usage total is observed.
- In bar style, two compact bars below the pet show short-window and weekly remaining capacity.
- In bar style, percentages and reset countdowns are shown beside the bars.
- Ring style stays centered around the pet and shows the same short-window and weekly values in two fixed lower translucent readout badges.
- Dragging the pet makes the overlay follow the gesture immediately while Codex persists the new position when mouse monitoring is enabled.
- Closing the Codex pet hides the overlay.
- Multi-display positioning uses the screen containing the pet bounds, not the currently focused screen.
- macOS desktop/Space switching keeps the overlay visible with the pet rather than tying it to one active desktop.
- Switching to another Codex pet requires no extra setup; the overlay follows the active pet.

## Data Flow

The app reads local Codex files only:

- `~/.codex/.codex-global-state.json`: current pet bounds, using `electron-avatar-overlay-bounds.mascot`.
- `electron-avatar-overlay-open` in the same state file: whether the Codex pet is currently open.
- `~/.codex/sqlite/logs_2.sqlite` or legacy `~/.codex/logs_2.sqlite`: usage source using the newest websocket `codex.rate_limits` event and recent response `usage` token counters from `target = 'codex_api::endpoint::responses_websocket'`.
- `~/.codex/sessions/**/rollout-*.jsonl`: optional `Stop` hook worker source for `collaboration_mode_kind`, used only to skip Plan mode turns from finalized turn-usage records.
- `~/.codex/codex-pet-limit-rings/settings.json`: app-written `Track Turn Usage` setting used by the optional hook to no-op when tracking is off.
- `~/.codex/codex-pet-limit-rings/turn-usage-queue.jsonl`: optional bounded local queue used by the `Stop` hook worker, containing ids, the local transcript path when Codex provides one, enqueue timestamps, and retry counters.
- `~/.codex/codex-pet-limit-rings/turn-usage.json`: optional finalized turn-usage records written by the opt-in `Stop` hook, containing ids, Plan mode skip markers, response ids when present, timestamps, call counts, raw token counters, and goal-style `effective_tokens`.
- `~/.codex/codex-pet-limit-rings/turn-usage-ledger.json`: optional bounded per-turn ledger written by the opt-in `Stop` hook, used to avoid duplicate summary accumulation.
- `~/.codex/codex-pet-limit-rings/turn-usage-summary.json`: optional ledger rollup written by the opt-in `Stop` hook, containing today's and the latest session's token totals.
- `~/.codex/codex-pet-limit-rings/turn-usage-hook.log`: optional bounded hook diagnostic log with hook status, timestamps, ids, mode kind when detected, Plan mode skip markers, and call counts.

The app watches `~/.codex/.codex-global-state.json` with a macOS file event source, so pet open/close and position writes trigger an immediate frame update. A slow frame timer remains as a fallback in case the file is replaced or an event is missed.

No OpenAI API key is required. The app does not read `~/.codex/auth.json` and does not call a remote usage endpoint. The menu summary says `Local` when it is showing the local event-log value.
Use `--no-mouse-monitor` to disable global mouse event monitoring; this disables drag-follow while the usage overlay remains visible. The helper scripts apply that mode when `CODEX_PET_LIMIT_RINGS_NO_MOUSE_MONITOR=1` is set.

## Rendering Model

- Ring style is the default and draws short-window and weekly remaining capacity around the pet with fixed lower translucent readouts.
- Bar style draws the short-window remaining percentage and reset countdown in the top bar.
- Bar style draws the weekly remaining percentage and reset countdown in the bottom bar.
- Colors are derived from remaining capacity: green/blue for healthy, amber for low, red for critical.
- Bar outlines stay visible, and a short moving gradient sweep appears on each bar after local usage-log checks, which normally run every 20 seconds.
- Ring style uses the same color model and is drawn around the pet with fixed lower translucent readouts.
- When `Track Turn Usage` is enabled, menu token details include a bounded-ledger `Used` rollup and recent `thread_id + turn_id` groups, with reusable `W0` through `W9` labels assigned per `thread_id`.
- When the optional `Stop` hook is installed, turn-usage rows are merged from the hook-written state file and recent local response `usage` rows in SQLite; duplicate turns keep the record with more observed calls or token counters.
- When `Track Turn Usage` and `Show Usage Toasts` are enabled, the usage toast shows the latest goal-style `Used` token counter for a few seconds.
- The overlay is drawn with no panel background, so only the bars/rings and text are visible.
- Menu-driven display style, bar position offsets, and bar-width presets are saved in `UserDefaults`.

See `docs/recent-usage.md` for the token-counter menu semantics, raw counter inspection, window-slot labels, turn grouping, and limit-delta caveats.

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

`tools/uninstall-limit-rings.sh` unloads the LaunchAgent, removes the app bundle, clears saved overlay visibility and layout preferences, and also cleans up those earlier prototype names.

The build, install, and uninstall scripts refuse destructive app-bundle operations outside the repository `tmp/` app path or the default `~/Applications/CodexPetLimitRings.app` and `~/Applications/CodexLimitAura.app` paths.

Turn usage can optionally use a Codex `Stop` hook. This is separate from the app installer because it modifies Codex hook config:

```bash
tools/install-turn-usage-hook.sh
```

The hook installer copies the hook script into:

```text
~/.codex/codex-pet-limit-rings/hooks/codex-turn-usage-stop-hook.py
```

and registers an inline `[[hooks.Stop]]` entry in `~/.codex/config.toml`. It also enables `codex_hooks` in the same file. Restart Codex sessions after installing or uninstalling the hook so Codex reloads hook configuration.

This hook path has more setup than the default SQLite fallback: Codex must trust the local hook command, and existing sessions must restart before it runs. It is still optional. Use it when you want finalized turn-usage records from Codex's `Stop` event; the hook queues the turn and returns immediately, then a short-lived worker reads SQLite and writes the compact result. The app still keeps the periodic recent-log polling fallback and merges both sources.

The hook remains installed when the menu's `Track Turn Usage` item is off, but it exits immediately based on the app-written settings file and does not update turn-usage state.

To remove only the turn-usage hook:

```bash
tools/uninstall-turn-usage-hook.sh
```

## Development

Build and run the app from the repository:

```bash
tools/run-limit-rings.sh
```

Render a static preview:

```bash
swiftc tools/codex-pet-limit-rings.swift -o tmp/codex-pet-limit-rings -framework AppKit -lsqlite3
tmp/codex-pet-limit-rings --preview tmp/limit-rings-preview.png --size 164
```

## Codex Skill

The repository includes a skill at `skills/codex-pet-limit-rings/`. Copy that folder into `~/.codex/skills/` or run `tools/install-codex-skill.sh` to make Codex auto-discover the workflow in future sessions.

The skill intentionally points agents at the companion-app boundary and validation commands. It should not encourage app-bundle patching as the default path.
