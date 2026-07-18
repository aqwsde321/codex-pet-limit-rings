# Changelog

Notable changes to `codex-pet-limit-rings` are recorded here.

## Unreleased

### Removed

- 턴별 토큰 추적, 최근 턴 메뉴, 한도 변화량, 사용량 토스트와 선택형 Stop hook 설치기를 제거했습니다.

### Added

- 링과 바 위치를 메뉴에서 이동·초기화할 수 있고, 각 위치는 별도로 저장됩니다. 위치 컨트롤은 반복 조정 중 메뉴를 열린 상태로 유지합니다.
- 바 너비를 짧게, 보통, 넓게 중 하나로 선택할 수 있습니다.
- Bar outlines stay visible, and a short moving gradient sweep appears on each bar after local usage-log checks.
- Usage bars now show reset countdowns beneath the remaining percentage when reset data is available.

### Changed

- The overlay now uses compact progress bars under the pet instead of large circular rings.
- Bar tracks and outlines are slightly thicker and higher contrast for better visibility.
- The progress bar background panel is now transparent, leaving only the bars and text visible.
- Progress bars are shorter and centered closer to the pet so they do not protrude as far left.
- Reset countdown text uses compact proportional styling so hour/minute labels stay readable without making the panel feel busy.
- The overlay now follows pet drags from the live Codex overlay window at drag-time, reducing visible lag when moving the pet.
- Usage data now comes from local `codex.rate_limits` logs only; the app no longer reads `~/.codex/auth.json` or calls the remote usage endpoint.
- Usage lookup now targets websocket rate-limit events and preserves the log timestamp for stale-data display.
- Build, install, and uninstall scripts now refuse unsafe app-bundle paths before destructive operations.
- Global mouse event monitoring can now be disabled with `--no-mouse-monitor` or `CODEX_PET_LIMIT_RINGS_NO_MOUSE_MONITOR=1` in helper scripts.
- No-mouse-monitor mode now keeps usage values visible while disabling drag-follow.
- Usage detail text now avoids custom kerning and bounded text drawing to prevent AppKit/CoreText text crashes.

### Fixed

- Usage tracking now follows Codex SQLite logs after the active database moved under `~/.codex/sqlite/`, while keeping legacy log paths supported.
- Cross-display pet drags bridge brief live-overlay coordinate gaps from the mouse-to-pet offset instead of waiting for persisted pet state to catch up.
