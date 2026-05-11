# codex-pet-limit-rings

Codex pets are tiny ambient companions for the work happening in Codex. This project adds one more layer to that idea: your pet can quietly show how much Codex capacity you have left, without turning the app into a dashboard.

The experience is a small macOS companion app. It watches where the Codex pet is, draws either the default usage rings around it or compact usage bars under it, and keeps that overlay attached to the pet as it moves. It does not patch Codex, change pet art, or modify the Codex app bundle.

It works with whatever Codex pet you like. Built-in pet, custom pet, tiny dog, robot, weather daemon, or anything else: the app does not care. It only follows the pet window that Codex is already showing.

![Codex pet usage overlay in optional bar style near a Codex pet](docs/assets/codex-pet-limit-rings-screenshot.png)

## What You See

The default overlay is a pair of rings around the pet:

- The outer ring shows the short-window limit remaining.
- The inner ring shows the weekly limit remaining.
- Percentages and reset countdowns are shown in compact readout badges.
- The menu's `Display Style` item can switch to compact bars below the pet.
- In bar style, the top bar shows the short-window limit remaining and the bottom bar shows the weekly limit remaining.
- Color moves from calm green/blue to amber and red as capacity gets low.
- A small menu-bar icon lets you inspect recent token usage, hide the overlay, switch between bars and rings, adjust bar position and width, refresh data, or quit.
- `Track Turn Usage` is off by default. When enabled, a short toast appears near the overlay when a new turn's token usage is observed.

The menu's `Display Style` item switches between `Rings` and `Bars`; new installs default to `Rings`. `Track Turn Usage` defaults to off and can be enabled from the menu when you want recent turn token toasts and menu rows. Position and width controls apply to the bar style; the ring style stays centered around the pet.
When turn tracking is enabled, the same menu also shows recent window/turn token counts from local usage events and the latest short/weekly limit delta.

When the Codex pet is closed, the overlay disappears. When the pet comes back, it comes back too. On multi-display setups, the overlay stays with the pet instead of jumping to whichever screen is focused.

Because the usage overlay is drawn in a separate transparent window, it does not need pet-specific sprites, masks, metadata, or configuration. Change pets in Codex and the overlay follows the new one automatically.

## Track Turn Usage

`Track Turn Usage` is an optional local estimate for recent Codex turns. It is off by default. When enabled, the app reads response `usage` counters grouped by `thread_id + turn_id`.

By default, it can fall back to recent rows in the local Codex SQLite log. For cleaner end-of-turn updates, install the optional Codex `Stop` hook:

```bash
tools/install-turn-usage-hook.sh
```

The hook runs when Codex stops a turn, sums that turn's local `response.completed` usage rows, and writes compact counters to `~/.codex/codex-pet-limit-rings/turn-usage.json`. The menu-bar app reads that small state file and recent SQLite rows, merges them by `thread_id + turn_id`, and keeps the more complete duplicate when both sources contain the same turn.

The hook is optional because it has more setup than the fallback reader. It modifies Codex hook config, requires Codex to trust the hook command, and needs Codex sessions to be restarted after install or uninstall. The tradeoff is better finalized records: hook records arrive after Codex finishes a turn, while fallback rows can still appear from periodic log polling.

Use the fallback reader when you want the simplest setup. Use the hook when you want cleaner per-turn accounting and are comfortable with the extra local Codex hook configuration.

The menu and toast show:

- `N`: estimated net tokens, calculated as `max(0, In - Cached) + Out`.
- `I`: input tokens reported by the response usage object.
- `Ca`: cached input tokens reported by the response usage object.
- `O`: output tokens reported by the response usage object.
- `2c`, `3c`, and similar counts: multiple response usage events observed inside the same grouped turn.

These values are useful for understanding recent local activity, but they are not a billing calculator or the official rate-limit formula. `Limit delta` is separate: it compares consecutive local `codex.rate_limits` events and can include other active Codex windows.

See `docs/recent-usage.md` for the full semantics and known limits.

## Why It Works This Way

The important design choice is the companion boundary. A menu item inside Codex itself would mean patching Electron app files and redoing that patch after app updates. That is brittle and hard to open source.

`codex-pet-limit-rings` stays outside the Codex app. It reads local Codex state and the latest local `codex.rate_limits` event, then renders its own transparent always-on-top window under the pet. The result is reversible, inspectable, and easy for another Codex agent to install or modify.

Pet wakeups are handled by a lightweight filesystem watcher on Codex's local global-state file, with a slow fallback timer as a safety net. That lets the overlay snap back when the pet is re-enabled without constantly polling for position changes.

## Quick Start

Install the companion app as a login item:

```bash
tools/install-limit-rings.sh
```

You should see a small usage icon in the macOS menu bar. Use that menu to toggle `Track Turn Usage`, inspect recent token usage, toggle `Show Usage Overlay`, switch `Display Style`, adjust bar-only layout controls, refresh the latest usage data, or quit. The usage summary includes how old the local rate-limit log entry is.

Then use any Codex pet normally. No pet setup step is required.

Run a development build without installing the login item:

```bash
tools/run-limit-rings.sh
```

Uninstall everything the installer adds:

```bash
tools/uninstall-limit-rings.sh
```

Remove only the optional turn-usage hook:

```bash
tools/uninstall-turn-usage-hook.sh
```

## Give This Repo To Codex

This repository is structured so a Codex agent can pick it up from a GitHub link.

Ask the agent:

```text
Use the bundled codex-pet-limit-rings skill from this repository. Install the usage-overlay companion for my Codex pet, verify the LaunchAgent is running, and confirm the overlay stays anchored to the pet.
```

The agent should read:

- `AGENTS.md` for the project contract.
- `skills/codex-pet-limit-rings/SKILL.md` for the install, debug, and validation workflow.
- `docs/limit-rings.md` for the data and rendering model.
- `docs/recent-usage.md` for the menu token-counter semantics.

To install the bundled skill into local Codex:

```bash
tools/install-codex-skill.sh
```

## Data And Privacy

The app reads only local Codex files:

- `~/.codex/.codex-global-state.json` tells it whether the pet is open and where it is.
- `~/.codex/logs_2.sqlite` provides the latest local websocket `codex.rate_limits` event and recent response `usage` token counters.
- `~/.codex/codex-pet-limit-rings/turn-usage.json` is optionally written by the Codex `Stop` hook and contains session/thread/turn ids, timestamps, call counts, and token counters.
- `~/.codex/codex-pet-limit-rings/turn-usage-hook.log` is an optional bounded diagnostic log for the hook and contains hook status, timestamps, session/turn ids, and call counts.

It does not require an OpenAI API key, does not read `~/.codex/auth.json`, and does not call a remote usage endpoint. It does not send pet images, screenshots, prompts, or repo contents anywhere.

For stricter local privacy, run the binary with `--no-mouse-monitor` to disable global mouse event monitoring. The overlay still follows Codex's persisted pet state and keeps the usage values visible, but drag-follow is disabled.
Set `CODEX_PET_LIMIT_RINGS_NO_MOUSE_MONITOR=1` when running `tools/run-limit-rings.sh` or `tools/install-limit-rings.sh` to apply the same mode through the helper scripts.

## Project Shape

```text
tools/
  codex-pet-limit-rings.swift      native macOS companion app
  codex-turn-usage-stop-hook.py    optional Codex Stop hook writer
  install-limit-rings.sh           build, install, and start at login
  uninstall-limit-rings.sh         remove the app and login item
  install-turn-usage-hook.sh       opt in to Stop-hook turn usage
  uninstall-turn-usage-hook.sh     remove the optional Stop hook
  run-limit-rings.sh               development launch
  build-limit-rings.sh             app bundle builder
  install-codex-skill.sh           copy the bundled skill into ~/.codex/skills

skills/codex-pet-limit-rings/
  SKILL.md                         Codex-agent workflow for this project

docs/
  limit-rings.md                   implementation contract and data flow
  recent-usage.md                  Track Turn Usage semantics and caveats

experiments/weather-pets/
  earlier weather-pet renderer     kept as a separate experiment
```

## Development

Build the app:

```bash
tools/build-limit-rings.sh
```

Render a static preview PNG:

```bash
swiftc tools/codex-pet-limit-rings.swift -o tmp/codex-pet-limit-rings -framework AppKit -lsqlite3
tmp/codex-pet-limit-rings --preview tmp/limit-rings-preview.png --size 164
```

Validate the shell scripts:

```bash
bash -n tools/*.sh
```

## Experiments

The original exploration included a Python renderer for weather-mutated Codex pets. That work now lives under `experiments/weather-pets/` so the public repo can stay focused on limit rings while preserving the larger idea: Codex pets can become ambient interfaces for state, context, and mood.

## License

MIT. See `LICENSE`.
