#!/usr/bin/env python3
import fcntl
import json
import os
import signal
import sqlite3
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path


TARGET = "codex_api::endpoint::responses_websocket"
MAX_LOG_ROWS = 2000
MAX_RECORDS = 30
MAX_LEDGER_RECORDS = 500
MAX_LEDGER_AGE_SECONDS = 7 * 24 * 60 * 60
MAX_WAIT_SECONDS = 2.5
MAX_RUNTIME_SECONDS = 8.0
MAX_WORKER_LOCK_WAIT_SECONDS = 35.0
MAX_WORKER_RUNTIME_SECONDS = 30.0
RETRY_INTERVAL_SECONDS = 0.25
STABLE_READS_REQUIRED = 1
SQLITE_BUSY_TIMEOUT_SECONDS = 0.15
MAX_DIAGNOSTIC_LOG_BYTES = 128 * 1024
QUEUE_FIRST_ATTEMPT_DELAY_SECONDS = 1.5
QUEUE_RETRY_DELAY_SECONDS = 2.0
MAX_QUEUE_JOB_AGE_SECONDS = 10 * 60
MAX_QUEUE_JOBS = 200
MAX_QUEUE_BYTES = 256 * 1024
WORKER_ENV = "CODEX_PET_LIMIT_RINGS_WORKER"


class HookRuntimeTimeout(Exception):
    pass


def raise_runtime_timeout(signum, frame):
    raise HookRuntimeTimeout()


def install_runtime_alarm(timeout_seconds=MAX_RUNTIME_SECONDS):
    signal.signal(signal.SIGALRM, raise_runtime_timeout)
    signal.setitimer(signal.ITIMER_REAL, timeout_seconds)


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
    if os.environ.get(WORKER_ENV) == "1":
        return worker_main()

    payload = {}
    try:
        install_runtime_alarm()
        if not turn_usage_enabled():
            print(json.dumps({"continue": True}, separators=(",", ":")))
            return 0
        payload = json.load(sys.stdin)
        with lifecycle_lock():
            if not turn_usage_enabled():
                print(json.dumps({"continue": True}, separators=(",", ":")))
                return 0
            job = build_queue_job(payload)
            if job is not None:
                enqueue_job(job)
                spawn_worker()
                log_status("queued", payload)
            else:
                log_status("missing_turn", payload)
    except HookRuntimeTimeout:
        cancel_runtime_alarm()
        log_status("timeout", payload)
    except Exception:
        log_status("error", payload)
    finally:
        cancel_runtime_alarm()
    print(json.dumps({"continue": True}, separators=(",", ":")))
    return 0


def worker_main() -> int:
    try:
        install_runtime_alarm(MAX_WORKER_LOCK_WAIT_SECONDS + MAX_WORKER_RUNTIME_SECONDS)
        if clear_queue_when_disabled():
            return 0
        lock_deadline = time.monotonic() + MAX_WORKER_LOCK_WAIT_SECONDS
        worker_lock = acquire_worker_lock(lock_deadline)
        if worker_lock is None:
            return 0
        with worker_lock:
            install_runtime_alarm(MAX_WORKER_RUNTIME_SECONDS)
            processing_deadline = time.monotonic() + MAX_WORKER_RUNTIME_SECONDS - 0.5
            if clear_queue_when_disabled():
                return 0
            process_queue_until_idle(processing_deadline)
    except HookRuntimeTimeout:
        cancel_runtime_alarm()
        log_status("worker_timeout", {})
    except Exception:
        log_status("worker_error", {})
    finally:
        cancel_runtime_alarm()
    return 0


def turn_usage_enabled():
    settings_path = default_settings_path()
    try:
        with open(settings_path, "r", encoding="utf-8") as settings_file:
            settings = json.load(settings_file)
        if not isinstance(settings, dict):
            return False
        return settings.get("track_turn_usage") is True
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return False


def build_queue_job(payload):
    turn_id = payload.get("turn_id")
    if not isinstance(turn_id, str) or not turn_id:
        return None

    job = {
        "version": 1,
        "turn_id": turn_id,
        "enqueued_at": time.time(),
        "attempts": 0,
    }
    for key in ("session_id", "thread_id", "conversation_id"):
        value = payload.get(key)
        if isinstance(value, str) and value:
            job[key] = value
    return job


def enqueue_job(job):
    queue_path = default_queue_path()
    ensure_private_dir(queue_path.parent)
    lock_path = default_queue_lock_path()
    with open_private_text(lock_path, os.O_RDWR | os.O_CREAT | os.O_APPEND, "a+") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        jobs = read_queue_jobs(queue_path)
        jobs.append(job)
        write_queue_jobs(queue_path, compact_queue_jobs(jobs))


def spawn_worker():
    env = os.environ.copy()
    env[WORKER_ENV] = "1"
    try:
        subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve())],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
            close_fds=True,
            start_new_session=True,
        )
    except Exception:
        pass


def acquire_worker_lock(deadline=None):
    lock_path = default_worker_lock_path()
    ensure_private_dir(lock_path.parent)
    lock_file = open_private_text(lock_path, os.O_RDWR | os.O_CREAT | os.O_APPEND, "a+")
    while True:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return lock_file
        except BlockingIOError:
            if deadline is None or time.monotonic() >= deadline:
                lock_file.close()
                return None
            time.sleep(0.1)


def process_queue_until_idle(deadline):
    while time.monotonic() < deadline:
        if clear_queue_when_disabled():
            return

        job, wait_seconds = next_ready_queue_job()
        if job is None:
            if wait_seconds is None:
                return
            sleep_seconds = min(wait_seconds, max(0.0, deadline - time.monotonic()))
            if sleep_seconds <= 0:
                return
            time.sleep(sleep_seconds)
            continue

        payload = queue_job_payload(job)
        if clear_queue_when_disabled():
            return

        mode_kind = turn_collaboration_mode_kind(payload)
        if mode_kind:
            payload["collaboration_mode_kind"] = mode_kind
        if is_plan_mode_turn(payload):
            with lifecycle_lock():
                if not turn_usage_enabled():
                    clear_queue()
                    return
                remove_queue_job(job)
                log_status("skipped_plan_mode", payload)
            continue

        record = build_usage_record(payload, turn_usage_enabled)
        if clear_queue_when_disabled():
            return

        if record is not None:
            with lifecycle_lock():
                if not turn_usage_enabled():
                    clear_queue()
                    return
                append_state_record(record)
                remove_queue_job(job)
                log_status("recorded", payload, calls=len(record["calls"]))
        else:
            with lifecycle_lock():
                if not turn_usage_enabled():
                    clear_queue()
                    return
                retry_queue_job(job)
                log_status("pending", payload)


def clear_queue_when_disabled():
    with lifecycle_lock():
        if turn_usage_enabled():
            return False
        clear_queue()
        return True


@contextmanager
def lifecycle_lock():
    lock_path = default_lifecycle_lock_path()
    ensure_private_dir(lock_path.parent)
    with open_private_text(lock_path, os.O_RDWR | os.O_CREAT | os.O_APPEND, "a+") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        yield


def next_ready_queue_job():
    queue_path = default_queue_path()
    lock_path = default_queue_lock_path()
    ensure_private_dir(queue_path.parent)
    with open_private_text(lock_path, os.O_RDWR | os.O_CREAT | os.O_APPEND, "a+") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        jobs = compact_queue_jobs(read_queue_jobs(queue_path))
        write_queue_jobs(queue_path, jobs)

    if not jobs:
        return None, None

    now = time.time()
    waits = []
    for job in jobs:
        ready_at = queue_job_ready_at(job)
        if ready_at <= now:
            return job, None
        waits.append(ready_at - now)
    return None, max(0.0, min(waits)) if waits else None


def retry_queue_job(job):
    queue_path = default_queue_path()
    lock_path = default_queue_lock_path()
    job_key = queue_job_key(job)
    with open_private_text(lock_path, os.O_RDWR | os.O_CREAT | os.O_APPEND, "a+") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        jobs = []
        for existing in read_queue_jobs(queue_path):
            if queue_job_key(existing) == job_key:
                existing["attempts"] = int(existing.get("attempts") or 0) + 1
                existing["last_attempt_at"] = time.time()
            jobs.append(existing)
        write_queue_jobs(queue_path, compact_queue_jobs(jobs))


def remove_queue_job(job):
    queue_path = default_queue_path()
    lock_path = default_queue_lock_path()
    job_key = queue_job_key(job)
    with open_private_text(lock_path, os.O_RDWR | os.O_CREAT | os.O_APPEND, "a+") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        jobs = [existing for existing in read_queue_jobs(queue_path) if queue_job_key(existing) != job_key]
        write_queue_jobs(queue_path, compact_queue_jobs(jobs))


def clear_queue():
    queue_path = default_queue_path()
    tmp_path = queue_tmp_path(queue_path)
    if not queue_path.exists() and not tmp_path.exists():
        return

    lock_path = default_queue_lock_path()
    ensure_private_dir(queue_path.parent)
    with open_private_text(lock_path, os.O_RDWR | os.O_CREAT | os.O_APPEND, "a+") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        write_queue_jobs(queue_path, [])


def read_queue_jobs(queue_path):
    jobs = []
    try:
        with open(queue_path, "r", encoding="utf-8") as handle:
            for line in handle:
                try:
                    job = json.loads(line)
                except json.JSONDecodeError:
                    continue
                normalized = normalize_queue_job(job)
                if normalized is not None:
                    jobs.append(normalized)
    except FileNotFoundError:
        return []
    except OSError:
        return []
    return jobs


def write_queue_jobs(queue_path, jobs):
    ensure_private_dir(queue_path.parent)
    tmp_path = queue_tmp_path(queue_path)
    if not jobs:
        tmp_path.unlink(missing_ok=True)
        queue_path.unlink(missing_ok=True)
        fsync_parent_dir(queue_path.parent)
        return

    with open_private_text(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, "w") as tmp_file:
        for job in jobs:
            tmp_file.write(json.dumps(job, separators=(",", ":"), sort_keys=True))
            tmp_file.write("\n")
        tmp_file.flush()
        os.fsync(tmp_file.fileno())
    os.replace(tmp_path, queue_path)
    os.chmod(queue_path, 0o600)
    fsync_parent_dir(queue_path.parent)


def compact_queue_jobs(jobs):
    now = time.time()
    by_key = {}
    for job in jobs:
        normalized = normalize_queue_job(job)
        if normalized is None:
            continue
        if now - normalized["enqueued_at"] > MAX_QUEUE_JOB_AGE_SECONDS:
            continue

        job_key = queue_job_key(normalized)
        existing = by_key.get(job_key)
        if existing is None:
            by_key[job_key] = normalized
            continue

        existing["enqueued_at"] = min(existing["enqueued_at"], normalized["enqueued_at"])
        existing["attempts"] = max(int(existing.get("attempts") or 0), int(normalized.get("attempts") or 0))
        for key in ("session_id", "thread_id", "conversation_id", "last_attempt_at"):
            if not existing.get(key) and normalized.get(key):
                existing[key] = normalized[key]

    compacted = sorted(by_key.values(), key=lambda item: item["enqueued_at"])
    if len(compacted) > MAX_QUEUE_JOBS:
        compacted = compacted[-MAX_QUEUE_JOBS:]

    while compacted and queue_jobs_size(compacted) > MAX_QUEUE_BYTES:
        compacted.pop(0)
    return compacted


def normalize_queue_job(job):
    if not isinstance(job, dict):
        return None
    turn_id = job.get("turn_id")
    if not isinstance(turn_id, str) or not turn_id:
        return None

    normalized = {"version": 1, "turn_id": turn_id}
    for key in ("session_id", "thread_id", "conversation_id"):
        value = job.get(key)
        if isinstance(value, str) and value:
            normalized[key] = value

    try:
        normalized["enqueued_at"] = float(job.get("enqueued_at"))
    except (TypeError, ValueError):
        normalized["enqueued_at"] = time.time()

    try:
        normalized["attempts"] = max(0, int(job.get("attempts") or 0))
    except (TypeError, ValueError):
        normalized["attempts"] = 0

    try:
        last_attempt_at = float(job.get("last_attempt_at"))
        if last_attempt_at > 0:
            normalized["last_attempt_at"] = last_attempt_at
    except (TypeError, ValueError):
        pass

    return normalized


def queue_job_key(job):
    return "|".join(str(job.get(key) or "") for key in ("session_id", "thread_id", "conversation_id", "turn_id"))


def queue_job_payload(job):
    payload = {}
    for key in ("session_id", "thread_id", "conversation_id", "turn_id", "collaboration_mode_kind"):
        value = job.get(key)
        if value:
            payload[key] = value
    return payload


def queue_job_ready_at(job):
    if int(job.get("attempts") or 0) > 0 and job.get("last_attempt_at"):
        return float(job["last_attempt_at"]) + QUEUE_RETRY_DELAY_SECONDS
    return float(job["enqueued_at"]) + QUEUE_FIRST_ATTEMPT_DELAY_SECONDS


def queue_jobs_size(jobs):
    return sum(len(json.dumps(job, separators=(",", ":"), sort_keys=True).encode("utf-8")) + 1 for job in jobs)


def fsync_parent_dir(parent):
    try:
        fd = os.open(parent, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def queue_tmp_path(queue_path):
    return queue_path.with_suffix(".jsonl.tmp")


def build_usage_record(payload, should_continue=None):
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
        if should_continue is not None and not should_continue():
            return None
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
    effective_tokens = effective_token_count(input_tokens, cached_tokens, output_tokens)
    observed_at = max(row["observed_at"] for row in rows)
    return {
        "thread_id": thread_id,
        "session_id": session_id,
        "turn_id": turn_id,
        "observed_at": observed_at,
        "input_tokens": input_tokens,
        "cached_tokens": cached_tokens,
        "output_tokens": output_tokens,
        "effective_tokens": effective_tokens,
        "calls": rows,
    }


def effective_token_count(input_tokens, cached_tokens, output_tokens):
    return max(0, input_tokens - cached_tokens) + max(0, output_tokens)


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
    seen_response_ids = set()
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

            response_id = response_id_for_event(event)
            if response_id:
                if response_id in seen_response_ids:
                    continue
                seen_response_ids.add(response_id)

            observed_at = float(ts) + (float(ts_nanos) / 1_000_000_000.0)
            cached_tokens = int((usage.get("input_tokens_details") or {}).get("cached_tokens") or 0)
            input_tokens = int(input_tokens)
            output_tokens = int(output_tokens)
            row = {
                "thread_id": row_thread_id,
                "observed_at": observed_at,
                "input_tokens": input_tokens,
                "cached_tokens": cached_tokens,
                "output_tokens": output_tokens,
                "effective_tokens": effective_token_count(input_tokens, cached_tokens, output_tokens),
            }
            if response_id:
                row["response_id"] = response_id
            rows.append(row)
    except sqlite3.Error:
        return []
    finally:
        db.close()

    rows = filter_identity_rows(rows, identity_candidates)
    return sorted(rows, key=lambda row: row["observed_at"])


def response_id_for_event(event):
    response = event.get("response")
    if isinstance(response, dict):
        response_id = response.get("id")
        if isinstance(response_id, str) and response_id:
            return response_id

    response_id = event.get("response_id")
    if isinstance(response_id, str) and response_id:
        return response_id

    return None


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


def turn_collaboration_mode_kind(payload):
    turn_id = payload.get("turn_id")
    if not isinstance(turn_id, str) or not turn_id:
        return None

    for path in transcript_path_candidates(payload):
        mode_kind = read_turn_collaboration_mode_kind(path, turn_id)
        if mode_kind:
            return mode_kind
    return None


def transcript_path_candidates(payload):
    candidates = []
    explicit_path = payload.get("transcript_path")
    if isinstance(explicit_path, str) and explicit_path:
        candidates.append(Path(explicit_path).expanduser())

    for key in ("session_id", "thread_id"):
        value = payload.get(key)
        if not isinstance(value, str) or not value:
            continue
        candidates.extend(session_transcript_paths(value))

    seen = set()
    unique_candidates = []
    for path in candidates:
        path_key = str(path)
        if path_key in seen:
            continue
        seen.add(path_key)
        unique_candidates.append(path)
    return unique_candidates


def session_transcript_paths(session_id):
    sessions_root = default_codex_home() / "sessions"
    if not sessions_root.exists():
        return []
    try:
        paths = list(sessions_root.rglob(f"rollout-*{session_id}.jsonl"))
    except OSError:
        return []
    return sorted(paths, key=path_mtime, reverse=True)


def path_mtime(path):
    try:
        return path.stat().st_mtime
    except OSError:
        return 0


def read_turn_collaboration_mode_kind(path, turn_id):
    try:
        with open(path, "r", encoding="utf-8") as transcript:
            for line in transcript:
                if turn_id not in line or "collaboration_mode_kind" not in line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                payload = event.get("payload") if isinstance(event, dict) else None
                if not isinstance(payload, dict):
                    continue
                if payload.get("type") not in ("task_started", "turn_started"):
                    continue
                if payload.get("turn_id") != turn_id:
                    continue
                mode_kind = payload.get("collaboration_mode_kind")
                if isinstance(mode_kind, str) and mode_kind:
                    return mode_kind.lower()
    except OSError:
        return None
    return None


def is_plan_mode_turn(payload):
    mode_kind = payload.get("collaboration_mode_kind")
    return isinstance(mode_kind, str) and mode_kind.lower() == "plan"


def usage_rows_signature(rows):
    return tuple(
        (
            row.get("thread_id"),
            row.get("response_id"),
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
        ledger_records = update_ledger_state(record, records)
        write_summary_state(ledger_records)


def update_ledger_state(record, seed_records):
    ledger_path = default_ledger_path()
    ensure_private_dir(ledger_path.parent)
    ledger_state = read_state(ledger_path)
    ledger_records = ledger_state.get("records") or []
    if not isinstance(ledger_records, list):
        ledger_records = []
    if not ledger_records:
        ledger_records = [compact_ledger_record(existing) for existing in seed_records]

    key = ledger_key(record)
    ledger_records = [
        existing for existing in ledger_records
        if ledger_key(existing) != key
    ]
    ledger_records.insert(0, compact_ledger_record(record))
    ledger_records = prune_ledger_records(ledger_records)
    state = {
        "version": 1,
        "updated_at": time.time(),
        "max_age_seconds": MAX_LEDGER_AGE_SECONDS,
        "max_records": MAX_LEDGER_RECORDS,
        "records": ledger_records,
    }
    tmp_path = ledger_path.with_suffix(".json.tmp")
    with open_private_text(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, "w") as tmp_file:
        json.dump(state, tmp_file, separators=(",", ":"), sort_keys=True)
        tmp_file.write("\n")
    os.replace(tmp_path, ledger_path)
    return ledger_records


def compact_ledger_record(record):
    compact = {
        "thread_id": record.get("thread_id"),
        "turn_id": record.get("turn_id"),
        "observed_at": record.get("observed_at"),
        "input_tokens": int(record.get("input_tokens") or 0),
        "cached_tokens": int(record.get("cached_tokens") or 0),
        "output_tokens": int(record.get("output_tokens") or 0),
        "effective_tokens": effective_tokens_for_record(record),
        "call_count": call_count_for_record(record),
    }
    session_id = record.get("session_id")
    if isinstance(session_id, str) and session_id:
        compact["session_id"] = session_id
    return compact


def prune_ledger_records(records):
    cutoff = time.time() - MAX_LEDGER_AGE_SECONDS
    deduped = []
    seen_keys = set()
    for record in sorted(records, key=lambda item: item.get("observed_at") or 0, reverse=True):
        observed_at = record.get("observed_at")
        if isinstance(observed_at, (int, float)) and float(observed_at) < cutoff:
            continue
        key = ledger_key(record)
        if key in seen_keys:
            continue
        seen_keys.add(key)
        deduped.append(record)
        if len(deduped) >= MAX_LEDGER_RECORDS:
            break
    return deduped


def ledger_key(record):
    return (
        record.get("thread_id") or record.get("session_id"),
        record.get("turn_id"),
    )


def write_summary_state(records):
    summary_path = default_summary_path()
    ensure_private_dir(summary_path.parent)
    today_key = time.strftime("%Y-%m-%d", time.localtime())
    latest_session_key = next((session_key_for_record(record) for record in records if session_key_for_record(record)), None)
    today_records = [
        record for record in records
        if date_key_for_record(record) == today_key
    ]
    latest_session_records = [
        record for record in records
        if latest_session_key and session_key_for_record(record) == latest_session_key
    ]
    summary = {
        "version": 1,
        "updated_at": time.time(),
        "source": "ledger",
        "record_count": len(records),
        "today": usage_totals(today_records, {"date": today_key}),
        "latest_session": usage_totals(latest_session_records, {"session_id": latest_session_key} if latest_session_key else {}),
    }
    tmp_path = summary_path.with_suffix(".json.tmp")
    with open_private_text(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, "w") as tmp_file:
        json.dump(summary, tmp_file, separators=(",", ":"), sort_keys=True)
        tmp_file.write("\n")
    os.replace(tmp_path, summary_path)


def usage_totals(records, extra):
    totals = {
        "turn_count": len(records),
        "call_count": sum(call_count_for_record(record) for record in records),
        "input_tokens": sum(int(record.get("input_tokens") or 0) for record in records),
        "cached_tokens": sum(int(record.get("cached_tokens") or 0) for record in records),
        "output_tokens": sum(int(record.get("output_tokens") or 0) for record in records),
        "effective_tokens": sum(effective_tokens_for_record(record) for record in records),
    }
    totals.update(extra)
    return totals


def call_count_for_record(record):
    call_count = record.get("call_count")
    if isinstance(call_count, int) and call_count > 0:
        return call_count
    calls = record.get("calls")
    return len(calls) if isinstance(calls, list) and calls else 1


def effective_tokens_for_record(record):
    effective_tokens = record.get("effective_tokens")
    if effective_tokens is not None:
        return int(effective_tokens)
    return effective_token_count(
        int(record.get("input_tokens") or 0),
        int(record.get("cached_tokens") or 0),
        int(record.get("output_tokens") or 0),
    )


def session_key_for_record(record):
    session_id = record.get("session_id")
    if isinstance(session_id, str) and session_id:
        return session_id
    thread_id = record.get("thread_id")
    return thread_id if isinstance(thread_id, str) and thread_id else None


def date_key_for_record(record):
    observed_at = record.get("observed_at")
    if not isinstance(observed_at, (int, float)):
        return None
    return time.strftime("%Y-%m-%d", time.localtime(float(observed_at)))


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


def default_summary_path():
    override = os.environ.get("CODEX_PET_LIMIT_RINGS_TURN_USAGE_SUMMARY")
    if override:
        return Path(override).expanduser()
    return default_codex_home() / "codex-pet-limit-rings" / "turn-usage-summary.json"


def default_ledger_path():
    override = os.environ.get("CODEX_PET_LIMIT_RINGS_TURN_USAGE_LEDGER")
    if override:
        return Path(override).expanduser()
    return default_codex_home() / "codex-pet-limit-rings" / "turn-usage-ledger.json"


def default_settings_path():
    override = os.environ.get("CODEX_PET_LIMIT_RINGS_SETTINGS")
    if override:
        return Path(override).expanduser()
    return default_codex_home() / "codex-pet-limit-rings" / "settings.json"


def default_queue_path():
    override = os.environ.get("CODEX_PET_LIMIT_RINGS_TURN_USAGE_QUEUE")
    if override:
        return Path(override).expanduser()
    return default_codex_home() / "codex-pet-limit-rings" / "turn-usage-queue.jsonl"


def default_queue_lock_path():
    return default_queue_path().with_suffix(".lock")


def default_worker_lock_path():
    return default_codex_home() / "codex-pet-limit-rings" / "turn-usage-worker.lock"


def default_lifecycle_lock_path():
    return default_codex_home() / "codex-pet-limit-rings" / "turn-usage-lifecycle.lock"


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
        mode_kind = payload.get("collaboration_mode_kind")
        if isinstance(mode_kind, str) and mode_kind:
            row["collaboration_mode_kind"] = mode_kind
        with open_private_text(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, "a") as handle:
            handle.write(json.dumps(row, separators=(",", ":"), sort_keys=True))
            handle.write("\n")
    except Exception:
        pass


def default_codex_home():
    return Path(os.environ.get("CODEX_HOME", "~/.codex")).expanduser()


if __name__ == "__main__":
    raise SystemExit(main())
