#!/usr/bin/env python3
import fcntl
import json
import os
import signal
import sqlite3
import sys
import time
from pathlib import Path


TARGET = "codex_api::endpoint::responses_websocket"
MAX_LOG_ROWS = 2000
MAX_RECORDS = 30
MAX_WAIT_SECONDS = 2.5
MAX_RUNTIME_SECONDS = 8.0
RETRY_INTERVAL_SECONDS = 0.25
STABLE_READS_REQUIRED = 1
SQLITE_BUSY_TIMEOUT_SECONDS = 0.15
MAX_DIAGNOSTIC_LOG_BYTES = 128 * 1024


class HookRuntimeTimeout(Exception):
    pass


def raise_runtime_timeout(signum, frame):
    raise HookRuntimeTimeout()


def install_runtime_alarm():
    signal.signal(signal.SIGALRM, raise_runtime_timeout)
    signal.setitimer(signal.ITIMER_REAL, MAX_RUNTIME_SECONDS)


def cancel_runtime_alarm():
    signal.setitimer(signal.ITIMER_REAL, 0)


def ensure_private_dir(path):
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)


def open_private_text(path, flags, mode):
    fd = os.open(path, flags, 0o600)
    try:
        os.fchmod(fd, 0o600)
        return os.fdopen(fd, mode, encoding="utf-8")
    except Exception:
        os.close(fd)
        raise


def main() -> int:
    payload = {}
    try:
        install_runtime_alarm()
        payload = json.load(sys.stdin)
        log_status("start", payload)
        record = build_usage_record(payload)
        if record is not None:
            append_state_record(record)
            log_status("recorded", payload, calls=len(record["calls"]))
        else:
            log_status("no_usage_rows", payload)
    except HookRuntimeTimeout:
        cancel_runtime_alarm()
        log_status("timeout", payload)
    except Exception:
        log_status("error", payload)
    finally:
        cancel_runtime_alarm()
    print(json.dumps({"continue": True}, separators=(",", ":")))
    return 0


def build_usage_record(payload):
    session_id = payload.get("session_id")
    turn_id = payload.get("turn_id")
    if not turn_id:
        return None

    identity_candidates = payload_identity_candidates(payload)
    deadline = time.monotonic() + MAX_WAIT_SECONDS
    rows = []
    last_signature = None
    stable_reads = 0
    while time.monotonic() <= deadline:
        current_rows = read_usage_rows(identity_candidates, turn_id)
        current_signature = usage_rows_signature(current_rows)
        if current_rows:
            rows = current_rows
            if current_signature == last_signature:
                stable_reads += 1
                if stable_reads >= STABLE_READS_REQUIRED:
                    break
            else:
                stable_reads = 0
                last_signature = current_signature
        time.sleep(RETRY_INTERVAL_SECONDS)

    if not rows:
        return None

    thread_id = rows[-1].get("thread_id") or session_id
    if not thread_id:
        return None

    input_tokens = sum(row["input_tokens"] for row in rows)
    cached_tokens = sum(row["cached_tokens"] for row in rows)
    output_tokens = sum(row["output_tokens"] for row in rows)
    observed_at = max(row["observed_at"] for row in rows)
    return {
        "thread_id": thread_id,
        "session_id": session_id,
        "turn_id": turn_id,
        "observed_at": observed_at,
        "input_tokens": input_tokens,
        "cached_tokens": cached_tokens,
        "output_tokens": output_tokens,
        "calls": rows,
    }


def payload_identity_candidates(payload):
    candidates = set()
    for key in ("session_id", "thread_id", "conversation_id"):
        value = payload.get(key)
        if isinstance(value, str) and value:
            candidates.add(value)
    return candidates


def read_usage_rows(identity_candidates, turn_id):
    logs_path = default_logs_path()
    if not logs_path.exists():
        return []

    rows = []
    try:
        db = sqlite3.connect(f"file:{logs_path}?mode=ro", timeout=SQLITE_BUSY_TIMEOUT_SECONDS, uri=True)
    except sqlite3.Error:
        return []

    try:
        db.execute(f"PRAGMA busy_timeout = {int(SQLITE_BUSY_TIMEOUT_SECONDS * 1000)}")
        query = """
            SELECT ts, ts_nanos, thread_id, feedback_log_body
            FROM logs INDEXED BY idx_logs_ts
            WHERE target = ?
              AND feedback_log_body LIKE '%"usage":{"input_tokens"%'
              AND feedback_log_body LIKE ?
            ORDER BY ts DESC, ts_nanos DESC, id DESC
            LIMIT ?
        """
        for ts, ts_nanos, row_thread_id, body in db.execute(query, (TARGET, f"%{turn_id}%", MAX_LOG_ROWS)):
            row_thread_id = row_thread_id or parse_delimited_value(body, "thread.id=")

            row_turn_id = (
                parse_delimited_value(body, "turn_id=")
                or parse_delimited_value(body, "turn.id=")
                or parse_delimited_value(body, "submission.id=")
            )
            if row_turn_id != turn_id:
                continue

            event = parse_event_json(body)
            if not event or event.get("type") != "response.completed":
                continue

            usage = event.get("usage") or (event.get("response") or {}).get("usage")
            if not usage:
                continue

            input_tokens = usage.get("input_tokens")
            output_tokens = usage.get("output_tokens")
            if input_tokens is None or output_tokens is None:
                continue

            observed_at = float(ts) + (float(ts_nanos) / 1_000_000_000.0)
            rows.append({
                "thread_id": row_thread_id,
                "observed_at": observed_at,
                "input_tokens": int(input_tokens),
                "cached_tokens": int((usage.get("input_tokens_details") or {}).get("cached_tokens") or 0),
                "output_tokens": int(output_tokens),
            })
    except sqlite3.Error:
        return []
    finally:
        db.close()

    rows = filter_identity_rows(rows, identity_candidates)
    return sorted(rows, key=lambda row: row["observed_at"])


def filter_identity_rows(rows, identity_candidates):
    if not rows:
        return []

    if identity_candidates:
        matched = [row for row in rows if row.get("thread_id") in identity_candidates]
        if matched:
            return matched

    known_thread_ids = {row["thread_id"] for row in rows if row.get("thread_id")}
    if len(known_thread_ids) == 1:
        only_thread_id = next(iter(known_thread_ids))
        return [row for row in rows if row.get("thread_id") == only_thread_id]

    return []


def usage_rows_signature(rows):
    return tuple(
        (
            row.get("thread_id"),
            row.get("observed_at"),
            row.get("input_tokens"),
            row.get("cached_tokens"),
            row.get("output_tokens"),
        )
        for row in rows
    )


def append_state_record(record):
    state_path = default_state_path()
    ensure_private_dir(state_path.parent)
    lock_path = state_path.with_suffix(".lock")
    with open_private_text(lock_path, os.O_RDWR | os.O_CREAT | os.O_APPEND, "a+") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        state = read_state(state_path)
        records = state.get("records") or []
        key = (record["thread_id"], record["turn_id"])
        records = [
            existing for existing in records
            if (existing.get("thread_id") or existing.get("session_id"), existing.get("turn_id")) != key
        ]
        records.insert(0, record)
        records = sorted(records, key=lambda item: item.get("observed_at") or 0, reverse=True)[:MAX_RECORDS]
        state = {
            "version": 1,
            "updated_at": time.time(),
            "records": records,
        }
        tmp_path = state_path.with_suffix(".json.tmp")
        with open_private_text(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, "w") as tmp_file:
            json.dump(state, tmp_file, separators=(",", ":"), sort_keys=True)
            tmp_file.write("\n")
        os.replace(tmp_path, state_path)


def read_state(state_path):
    try:
        with open(state_path, "r", encoding="utf-8") as state_file:
            state = json.load(state_file)
            return state if isinstance(state, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def parse_delimited_value(text, marker):
    start = text.find(marker)
    if start < 0:
        return None
    start += len(marker)
    if start < len(text) and text[start] in ("'", '"'):
        quote = text[start]
        start += 1
        end = text.find(quote, start)
        if end < 0:
            return None
        value = text[start:end]
        return value or None

    end = start
    delimiters = set(" \t\r\n,;)]}")
    while end < len(text) and text[end] not in delimiters:
        end += 1
    value = text[start:end]
    return value or None


def parse_event_json(text):
    start = text.find('{"type"')
    if start < 0:
        return None
    try:
        event, _ = json.JSONDecoder().raw_decode(text[start:])
        return event if isinstance(event, dict) else None
    except json.JSONDecodeError:
        return None


def default_logs_path():
    override = os.environ.get("CODEX_PET_LIMIT_RINGS_LOGS")
    if override:
        return Path(override).expanduser()
    codex_home = default_codex_home()
    logs2 = codex_home / "logs_2.sqlite"
    if logs2.exists():
        return logs2
    return codex_home / "logs_1.sqlite"


def default_state_path():
    override = os.environ.get("CODEX_PET_LIMIT_RINGS_TURN_USAGE_STATE")
    if override:
        return Path(override).expanduser()
    return default_codex_home() / "codex-pet-limit-rings" / "turn-usage.json"


def log_status(status, payload, calls=None):
    try:
        path = default_codex_home() / "codex-pet-limit-rings" / "turn-usage-hook.log"
        ensure_private_dir(path.parent)
        if path.exists() and path.stat().st_size > MAX_DIAGNOSTIC_LOG_BYTES:
            rotated = path.with_suffix(".log.1")
            try:
                os.replace(path, rotated)
            except OSError:
                path.unlink(missing_ok=True)
        row = {
            "at": time.time(),
            "status": status,
            "session_id": payload.get("session_id"),
            "turn_id": payload.get("turn_id"),
        }
        if calls is not None:
            row["calls"] = calls
        with open_private_text(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, "a") as handle:
            handle.write(json.dumps(row, separators=(",", ":"), sort_keys=True))
            handle.write("\n")
    except Exception:
        pass


def default_codex_home():
    return Path(os.environ.get("CODEX_HOME", "~/.codex")).expanduser()


if __name__ == "__main__":
    raise SystemExit(main())
