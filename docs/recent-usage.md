# Recent Usage Menu

This note documents the menu section that estimates recent Codex token usage from local logs.

## Goal

The overlay already shows remaining Codex limit percentages from local `codex.rate_limits` events. The recent usage menu adds a more detailed view of the latest token counters without reading authentication state or intercepting requests.

The menu is informational. It is not a billing calculator.

## What Track Turn Usage Controls

`Track Turn Usage` enables this whole recent-turn feature. It is off by default so the app only reads the local rate-limit event needed for the overlay rings or bars.

When `Track Turn Usage` is on, the app additionally:

- Reads finalized turn-usage records from the optional `Stop` hook state file when present.
- Also reads recent response `usage` rows from the local Codex SQLite log and merges both sources by `thread_id + turn_id`.
- Groups usage rows by `thread_id + turn_id`, or by local submission id if `turn_id` is missing.
- Sums multiple response usage events inside the same group and shows the count as `2c`, `3c`, and so on.
- Shows the grouped values in the menu and, briefly, shows the latest changed group in an overlay toast.
- Computes `Limit delta` from consecutive local `codex.rate_limits` events.

When `Track Turn Usage` is off, the app stops polling and parsing local turn-usage state, hides the recent-turn and limit-delta menu items, and clears any visible turn-usage toast. If the optional `Stop` hook is installed, the hook also reads the app-written setting and exits immediately without reading SQLite or updating turn-usage state/log files.

## Data Source

The app reads only local files. The app and optional `Stop` hook coordinate through:

```text
~/.codex/codex-pet-limit-rings/settings.json
```

This file stores whether `Track Turn Usage` is enabled. The hook treats a missing or malformed settings file as disabled.

```text
~/.codex/codex-pet-limit-rings/turn-usage-queue.jsonl
```

That file is a bounded local queue used by the optional `Stop` hook. The hook appends only local session/thread/turn ids, enqueue timestamps, and retry counters, then returns immediately. A background worker owns the SQLite read and removes a job only after the compact usage record is written. Jobs are deduplicated by local identity plus `turn_id`, retried briefly while SQLite catches up, and dropped after a short TTL or if the queue exceeds its size limits.

```text
~/.codex/codex-pet-limit-rings/turn-usage.json
```

That file contains full local session/thread/turn ids, observed/update timestamps, per-turn call counts, per-call timestamps, and token counters. It does not store prompt text, screenshots, repository contents, tool output, or auth data.

```text
~/.codex/codex-pet-limit-rings/turn-usage-summary.json
```

That file is a compact rollup derived from the recent `turn-usage.json` records. It contains today's and the latest session's `Used`, input, cached, output, turn-count, and call-count totals for the records still retained in local state.

The hook also writes a bounded local diagnostic log:

```text
~/.codex/codex-pet-limit-rings/turn-usage-hook.log
```

The diagnostic log contains hook status, timestamps, full local session and turn ids, and call counts. It is rotated at a small size and removed by `tools/uninstall-turn-usage-hook.sh`.

The app also reads local SQLite logs:

```text
~/.codex/logs_2.sqlite
```

If `logs_2.sqlite` does not exist, the app falls back to:

```text
~/.codex/logs_1.sqlite
```

Recent token counts come from `logs.feedback_log_body` rows where:

```sql
target = 'codex_api::endpoint::responses_websocket'
```

and the websocket event body contains a response `usage` object with token counters.

Limit delta comes from consecutive `codex.rate_limits` websocket events in the same table.

The app does not read:

```text
~/.codex/auth.json
```

It does not send prompts, screenshots, repository contents, token counters, or local log data anywhere.

## Optional Stop Hook

The repository includes an opt-in Codex `Stop` hook:

```bash
tools/install-turn-usage-hook.sh
```

The installer copies the hook script to:

```text
~/.codex/codex-pet-limit-rings/hooks/codex-turn-usage-stop-hook.py
```

and registers an inline `[[hooks.Stop]]` entry in `~/.codex/config.toml`. It also enables `codex_hooks` in the same file. Older installer versions used `~/.codex/hooks.json`; the current installer removes this package's legacy `hooks.json` entry to avoid duplicate runs.

When Codex ends a turn, the hook receives the Codex hook payload on stdin. It writes a small local queue job and returns so Codex does not wait on SQLite. A short-lived background worker then uses `turn_id` plus available local session/thread identifiers to find matching local `response.completed` usage rows in `logs_2.sqlite`, dedupes calls by `response.id` when present, sums the calls for that turn, writes the compact result to `turn-usage.json` with raw counters plus goal-style `effective_tokens`, and rewrites `turn-usage-summary.json` from the retained recent records.

This adds finalized hook records to the recent-turn behavior: Codex tells the hook when a turn stops, the worker writes a compact result, and the app reads that state file. The app still polls recent SQLite rows too, then merges both sources, so fallback rows can appear before a matching hook record is written.

The hook is installed independently from the menu toggle. The toggle controls collection by writing `settings.json`; when it is off, the installed hook returns immediately and does not touch SQLite.

To remove the hook:

```bash
tools/uninstall-turn-usage-hook.sh
```

Restart Codex sessions after installing or uninstalling hooks so Codex reloads hook configuration.

### Setup Cost

The hook is intentionally opt-in because it changes local Codex configuration outside this app:

1. Copies the hook script into `~/.codex/codex-pet-limit-rings/hooks/`.
2. Adds an inline `[[hooks.Stop]]` entry to `~/.codex/config.toml`.
3. Enables `codex_hooks` in `~/.codex/config.toml`.
4. Requires Codex to trust the hook command.
5. Requires existing Codex sessions to be restarted before the new hook config is active.

The app itself still works without this setup. Without the hook state file, `Track Turn Usage` shows recent local `response.completed` usage rows from SQLite. With both sources present, the app merges hook records and SQLite rows by `thread_id + turn_id` and keeps the duplicate with more observed calls or token counters.

### Hook vs SQLite Fallback

| Mode | Setup | Timing | Accuracy shape | Best for |
| --- | --- | --- | --- | --- |
| SQLite fallback | No Codex hook config | Periodic polling | Good recent-log estimate, but the app infers changes from polling | Zero-config local use |
| `Stop` hook | Install hook, trust command, restart sessions | Hook queues immediately; worker records after Codex stops a turn; fallback rows still poll | Cleaner `thread_id + turn_id` finalized records, with `c` equal to observed `response.completed` calls | Per-turn toast/menu behavior |

The hook is better for the current toast goal because Codex explicitly tells the hook when a turn stops. The queue keeps the hook fast while giving the worker a chance to read the final usage rows after SQLite catches up. The fallback remains active as a zero-config source and can surface rows from periodic polling before the hook record is available.

## Menu Shape

The menu shows up to three recent turn groups:

```text
Recent turns
Recent Used  Today 16.2k  |  Session 9.3k
W0/a327/81d2  2c  Used 8.5k  I192k  Ca186k  O1.6k
W1/8089/c1f4  1c  Used 7.7k  I7.7k  Ca0  O41

Limit delta  Short -0.4% | Weekly -0.1%
```

The recent usage rollup is based on retained hook records and is shown only when `turn-usage-summary.json` is available. The recent turn rows are compact and color-coded in the menu. They include a short `turn_id` suffix so repeated `W0/a327` rows can still be distinguished.

The `Track Turn Usage` menu item controls this whole section. Turning it off hides these rows and stops the extra local usage-log polling.

## Overlay Toast

The app polls recent usage state every few seconds. With the optional `Stop` hook installed, changed groups usually appear after Codex finishes a turn. Without the hook, changed groups come from recent local response `usage` rows. When the app sees changed turn groups, it shows up to three short toast cards for the groups changed in that polling pass near the current bars or rings:

```text
W0/81d2 2c  Used 4.0k
I258k  Ca254k  O298

W1/c1f4 1c  Used 7.9k
I7.8k  Ca0  O126
```

The toasts are intentionally temporary. `W0` through `W9` are reusable local window slots assigned by `thread_id`; the suffix after `/` is the shortened turn id for debugging. Toast cards represent groups changed in the latest polling pass; older visible cards are not carried forward into the next toast update. The menu remains the detailed view for up to three recent groups. Old groups are ignored for toast purposes even if they remain in the menu. `2c` means two response usage calls were observed for that card's turn group.

## Token Fields

`In` is the total input tokens reported by the response usage object. It can include the user message, conversation context, system and developer instructions, project instructions, file excerpts, diffs, terminal output, and tool results that the model saw.

`Cached` is the subset of input tokens reported as cached input. These are tokens the service says were reused from cache.

`Out` is the output tokens generated by the model.

`Used` is the goal-style token count shown first:

```text
Used = max(0, In - Cached) + Out
```

This matches the Codex goal accounting formula for the response usage rows the app can observe locally. It should not be treated as the exact account-wide rate-limit or billing formula because the app still depends on local logs and only groups observed response events.

## Thread Grouping

The app groups recent usage by `thread_id` plus `turn_id` when available. If `turn_id` is not available, it falls back to the local submission id.

For readability, the app maps recent `thread_id` values to `W0` through `W9`. Existing mappings are stored in `UserDefaults`, and the oldest inactive slot is reused when all ten slots are occupied.

For each recent `thread_id + turn_id` group, the app sums multiple usage events and shows the count as `2c`, `3c`, and so on.

This is intentionally conservative:

- It avoids mixing different threads when multiple Codex windows are active.
- It avoids showing a global token total as if it belonged to one question.
- It does not try to infer full conversation history or inspect prompt text.

If a usage event is missing `thread_id`, the app skips it for the recent turn list.

## Limit Delta

`Limit delta` compares the latest and previous local `codex.rate_limits` events:

```text
Short delta = latest short remaining percent - previous short remaining percent
Weekly delta = latest weekly remaining percent - previous weekly remaining percent
```

Example:

```text
previous: Short 86.4%, Weekly 47.2%
latest:   Short 86.0%, Weekly 47.1%

Limit delta  Short -0.4% | Weekly -0.1%
```

This is an account-level change. It is not attributed to a specific thread. If several Codex windows are active at the same time, the limit delta can include all of them.

## Known Limits

- `Used` is a goal-style local calculation from observed response usage rows, not the official account-wide rate-limit formula.
- `Recent Used` totals are derived from retained recent records, not a durable all-time daily ledger.
- Account-wide limit deltas can still differ from this per-turn response-usage formula.
- A single user-visible question can trigger multiple model calls; the hook reports these as multiple calls inside the same `thread_id + turn_id` when Codex logs them that way, deduping repeated `response.id` values when present.
- The app can aggregate multiple usage events inside a `turn_id`, but it does not inspect prompt text to infer semantic question boundaries.
- `Limit delta` is account-level and can be ambiguous during simultaneous work.
- Codex hooks are loaded by Codex sessions, so installing or uninstalling the hook requires restarting Codex sessions before behavior changes are visible.

The safest interpretation is:

```text
Recent turns = goal-style local token counters grouped by thread + turn
Limit delta = account-level remaining-limit movement
```
