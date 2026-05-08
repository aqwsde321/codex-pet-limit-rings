# Codex Pet Limit Rings

Codex Pet Limit Rings is a native macOS companion app for Codex pets. It does not patch Codex, replace pet art, or modify the Codex app bundle. It follows the current pet with a transparent always-on-top window and exposes its own menu-bar icon.

The usage overlay is pet-agnostic. It works with any pet Codex displays because the app tracks the pet window bounds rather than reading, editing, or understanding the pet artwork.

## Experience Contract

- A usage-bars icon appears in the macOS menu bar.
- `Show Usage Bars` toggles the overlay without quitting the app.
- `Refresh Now` rereads usage and pet-position state.
- The menu summary includes how old the local rate-limit log entry is.
- Two compact bars below the pet show short-window and weekly remaining capacity.
- Percentages and reset countdowns are always shown beside the bars.
- Dragging the pet makes the overlay follow the gesture immediately while Codex persists the new position when mouse monitoring is enabled.
- Closing the Codex pet hides the overlay.
- Multi-display positioning uses the screen containing the pet bounds, not the currently focused screen.
- macOS desktop/Space switching keeps the overlay visible with the pet rather than tying it to one active desktop.
- Switching to another Codex pet requires no extra setup; the overlay follows the active pet.

## Data Flow

The app reads local Codex files only:

- `~/.codex/.codex-global-state.json`: current pet bounds, using `electron-avatar-overlay-bounds.mascot`.
- `electron-avatar-overlay-open` in the same state file: whether the Codex pet is currently open.
- `~/.codex/logs_2.sqlite`: usage source using the newest websocket `codex.rate_limits` event from `target = 'codex_api::endpoint::responses_websocket'`.

The app watches `~/.codex/.codex-global-state.json` with a macOS file event source, so pet open/close and position writes trigger an immediate frame update. A slow frame timer remains as a fallback in case the file is replaced or an event is missed.

No OpenAI API key is required. The app does not read `~/.codex/auth.json` and does not call a remote usage endpoint. The menu summary says `Local` when it is showing the local event-log value.
Use `--no-mouse-monitor` to disable global mouse event monitoring; this disables drag-follow while the usage bars remain visible. The helper scripts apply that mode when `CODEX_PET_LIMIT_RINGS_NO_MOUSE_MONITOR=1` is set.

## Rendering Model

- Top bar: short-window remaining percentage and reset countdown.
- Bottom bar: weekly remaining percentage and reset countdown.
- Bar colors are derived from remaining capacity: green/blue for healthy, amber for low, red for critical.
- The overlay is drawn under the pet with no panel background, so only the bars and text are visible.

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

`tools/uninstall-limit-rings.sh` unloads the LaunchAgent, removes the app bundle, clears the saved overlay visibility preference, and also cleans up those earlier prototype names.

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
```

## Codex Skill

The repository includes a skill at `skills/codex-pet-limit-rings/`. Copy that folder into `~/.codex/skills/` or run `tools/install-codex-skill.sh` to make Codex auto-discover the workflow in future sessions.

The skill intentionally points agents at the companion-app boundary and validation commands. It should not encourage app-bundle patching as the default path.
