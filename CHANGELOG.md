# Changelog

Notable changes to `codex-pet-limit-rings` are recorded here.

## Unreleased

### Added

- Hover readouts now show a subtle reset countdown beneath the remaining percentage when reset data is available.

### Changed

- Reset countdown text uses compact proportional styling so hour/minute labels stay readable without making the capsule feel busy.
- Rings now follow pet drags from the live Codex overlay window at drag-time, reducing visible lag when moving the pet.
- Usage data now comes from local `codex.rate_limits` logs only; the app no longer reads `~/.codex/auth.json` or calls the remote usage endpoint.
- Usage lookup now targets websocket rate-limit events and preserves the log timestamp for stale-data display.
- Build, install, and uninstall scripts now refuse unsafe app-bundle paths before destructive operations.
- Global mouse event monitoring can now be disabled with `--no-mouse-monitor` or `CODEX_PET_LIMIT_RINGS_NO_MOUSE_MONITOR=1` in helper scripts.

### Fixed

- Cross-display pet drags bridge brief live-overlay coordinate gaps from the mouse-to-pet offset instead of waiting for persisted pet state to catch up.
