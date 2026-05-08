# Changelog

Notable changes to `codex-pet-limit-rings` are recorded here.

## Unreleased

### Added

- Usage bars now show reset countdowns beneath the remaining percentage when reset data is available.

### Changed

- The overlay now uses compact progress bars under the pet instead of large circular rings.
- Reset countdown text uses compact proportional styling so hour/minute labels stay readable without making the panel feel busy.
- The overlay now follows pet drags from the live Codex overlay window at drag-time, reducing visible lag when moving the pet.
- Usage data now comes from local `codex.rate_limits` logs only; the app no longer reads `~/.codex/auth.json` or calls the remote usage endpoint.
- Usage lookup now targets websocket rate-limit events and preserves the log timestamp for stale-data display.
- Build, install, and uninstall scripts now refuse unsafe app-bundle paths before destructive operations.
- Global mouse event monitoring can now be disabled with `--no-mouse-monitor` or `CODEX_PET_LIMIT_RINGS_NO_MOUSE_MONITOR=1` in helper scripts.
- No-mouse-monitor mode now keeps usage values visible while disabling drag-follow.
- Usage detail text now avoids custom kerning and bounded text drawing to prevent AppKit/CoreText text crashes.

### Fixed

- Cross-display pet drags bridge brief live-overlay coordinate gaps from the mouse-to-pet offset instead of waiting for persisted pet state to catch up.
