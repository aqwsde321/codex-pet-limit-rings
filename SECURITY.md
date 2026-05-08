# Security

`codex-pet-limit-rings` is local-first. It reads local Codex pet state and the latest local `codex.rate_limits` event from Codex logs.

By default it uses global mouse event monitoring for drag-follow. Run with `--no-mouse-monitor`, or set `CODEX_PET_LIMIT_RINGS_NO_MOUSE_MONITOR=1` for helper scripts, to disable mouse monitoring while keeping the usage bars visible.

Do not share Codex logs, screenshots containing private prompts, or generated files from `tmp/` when filing issues.

If you report a security issue, include the smallest source-level description needed to reproduce it. Do not include bearer tokens or local Codex data.
