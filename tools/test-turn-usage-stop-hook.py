#!/usr/bin/env python3
import importlib.util
import json
import os
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HOOK_PATH = ROOT / "tools" / "codex-turn-usage-stop-hook.py"


def load_hook():
    spec = importlib.util.spec_from_file_location("turn_usage_hook", HOOK_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_jsonl(path, rows):
    with open(path, "w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, separators=(",", ":")))
            handle.write("\n")


def write_json(path, value):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, separators=(",", ":"), sort_keys=True)
        handle.write("\n")


def transcript_day_dir(codex_home, timestamp):
    return Path(codex_home) / "sessions" / time.strftime("%Y/%m/%d", time.localtime(timestamp))


@contextmanager
def patched_env(values):
    old_values = {key: os.environ.get(key) for key in values}
    try:
        for key, value in values.items():
            os.environ[key] = str(value)
        yield
    finally:
        for key, value in old_values.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def test_reads_plan_mode_from_transcript(hook):
    with tempfile.TemporaryDirectory() as tmpdir:
        transcript_path = Path(tmpdir) / "rollout-test.jsonl"
        write_jsonl(
            transcript_path,
            [
                {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "turn-a", "collaboration_mode_kind": "default"}},
                {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "turn-b", "collaboration_mode_kind": "plan"}},
                {"type": "event_msg", "payload": {"type": "turn_complete", "turn_id": "turn-b"}},
            ],
        )

        assert hook.read_turn_collaboration_mode_kind(transcript_path, "turn-a") == "default"
        assert hook.read_turn_collaboration_mode_kind(transcript_path, "turn-b") == "plan"
        assert hook.read_turn_collaboration_mode_kind(transcript_path, "missing") is None


def test_detects_plan_mode_payload(hook):
    assert hook.is_plan_mode_turn({"collaboration_mode_kind": "plan"})
    assert hook.is_plan_mode_turn({"collaboration_mode_kind": "Plan"})
    assert not hook.is_plan_mode_turn({"collaboration_mode_kind": "default"})
    assert not hook.is_plan_mode_turn({})


def test_turn_mode_uses_explicit_transcript_path(hook):
    with tempfile.TemporaryDirectory() as tmpdir:
        transcript_path = Path(tmpdir) / "rollout-test.jsonl"
        write_jsonl(
            transcript_path,
            [
                {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "turn-c", "collaboration_mode_kind": "plan"}},
            ],
        )

        payload = {"turn_id": "turn-c", "transcript_path": str(transcript_path)}
        original = hook.session_transcript_paths
        def fail_session_scan(session_id):
            raise AssertionError("unexpected session scan")
        hook.session_transcript_paths = fail_session_scan
        try:
            assert hook.turn_collaboration_mode_kind(payload) == "plan"
        finally:
            hook.session_transcript_paths = original


def test_session_transcript_paths_limits_recent_candidates(hook):
    with tempfile.TemporaryDirectory() as tmpdir:
        session_id = "019e57af-test-session"
        now = time.time()
        day_dir = transcript_day_dir(tmpdir, now)
        day_dir.mkdir(parents=True)

        expected_paths = []
        for index in range(hook.MAX_TRANSCRIPT_CANDIDATES + 3):
            path = day_dir / f"rollout-2026-05-24T00-00-{index:02d}-{session_id}.jsonl"
            write_jsonl(path, [])
            mtime = now - index
            os.utime(path, (mtime, mtime))
            if index < hook.MAX_TRANSCRIPT_CANDIDATES:
                expected_paths.append(path)

        stale_path = day_dir / f"rollout-2026-05-24T00-01-00-{session_id}.jsonl"
        write_jsonl(stale_path, [])
        stale_mtime = now - hook.MAX_TRANSCRIPT_AGE_SECONDS - 60
        os.utime(stale_path, (stale_mtime, stale_mtime))

        with patched_env({"CODEX_HOME": tmpdir}):
            paths = hook.session_transcript_paths(session_id)

        assert paths == expected_paths
        assert stale_path not in paths


def test_queue_job_preserves_transcript_path(hook):
    job = hook.build_queue_job({
        "session_id": "thread-1",
        "turn_id": "turn-d",
        "transcript_path": "/tmp/rollout-test.jsonl",
    })

    assert job["transcript_path"] == "/tmp/rollout-test.jsonl"
    assert hook.queue_job_payload(job)["transcript_path"] == "/tmp/rollout-test.jsonl"


def test_default_logs_path_prefers_active_sqlite_dir(hook):
    with tempfile.TemporaryDirectory() as tmpdir:
        codex_home = Path(tmpdir)
        legacy_logs_path = codex_home / "logs_2.sqlite"
        sqlite_logs_path = codex_home / "sqlite" / "logs_2.sqlite"
        sqlite_logs_path.parent.mkdir()
        legacy_logs_path.touch()
        sqlite_logs_path.touch()
        os.utime(legacy_logs_path, (100, 100))
        os.utime(sqlite_logs_path, (200, 200))

        with patched_env({"CODEX_HOME": tmpdir}):
            assert hook.default_logs_path() == sqlite_logs_path


def test_default_logs_path_falls_back_to_legacy_path(hook):
    with tempfile.TemporaryDirectory() as tmpdir:
        legacy_logs_path = Path(tmpdir) / "logs_2.sqlite"
        legacy_logs_path.touch()

        with patched_env({"CODEX_HOME": tmpdir}):
            assert hook.default_logs_path() == legacy_logs_path


def test_skipped_turn_updates_state(hook):
    with tempfile.TemporaryDirectory() as tmpdir:
        state_path = Path(tmpdir) / "turn-usage.json"
        ledger_path = Path(tmpdir) / "turn-usage-ledger.json"
        summary_path = Path(tmpdir) / "turn-usage-summary.json"
        observed_at = time.time()
        write_json(ledger_path, {
            "version": 1,
            "records": [
                {
                    "thread_id": "thread-2",
                    "session_id": "thread-2",
                    "turn_id": "turn-plan",
                    "observed_at": observed_at,
                    "input_tokens": 1000,
                    "cached_tokens": 200,
                    "output_tokens": 50,
                    "effective_tokens": 850,
                    "call_count": 1,
                },
                {
                    "thread_id": "thread-2",
                    "session_id": "thread-2",
                    "turn_id": "turn-normal",
                    "observed_at": observed_at,
                    "input_tokens": 100,
                    "cached_tokens": 40,
                    "output_tokens": 10,
                    "effective_tokens": 70,
                    "call_count": 1,
                },
            ],
        })
        with patched_env({
            "CODEX_PET_LIMIT_RINGS_TURN_USAGE_STATE": state_path,
            "CODEX_PET_LIMIT_RINGS_TURN_USAGE_LEDGER": ledger_path,
            "CODEX_PET_LIMIT_RINGS_TURN_USAGE_SUMMARY": summary_path,
        }):
            hook.append_skipped_turn({
                "session_id": "thread-2",
                "turn_id": "turn-plan",
                "collaboration_mode_kind": "plan",
            })

        with open(state_path, "r", encoding="utf-8") as handle:
            state = json.load(handle)
        skipped_turn = state["skipped_turns"][0]
        assert skipped_turn["thread_id"] == "thread-2"
        assert skipped_turn["turn_id"] == "turn-plan"
        assert skipped_turn["reason"] == "plan_mode"
        with open(ledger_path, "r", encoding="utf-8") as handle:
            ledger = json.load(handle)
        with open(summary_path, "r", encoding="utf-8") as handle:
            summary = json.load(handle)
        assert [record["turn_id"] for record in ledger["records"]] == ["turn-normal"]
        assert summary["record_count"] == 1
        assert summary["today"]["effective_tokens"] == 70


def test_sync_existing_skipped_turns_rewrites_ledger_and_summary(hook):
    with tempfile.TemporaryDirectory() as tmpdir:
        state_path = Path(tmpdir) / "turn-usage.json"
        ledger_path = Path(tmpdir) / "turn-usage-ledger.json"
        summary_path = Path(tmpdir) / "turn-usage-summary.json"
        observed_at = time.time()
        plan_record = {
            "thread_id": "thread-4",
            "session_id": "thread-4",
            "turn_id": "turn-plan",
            "observed_at": observed_at,
            "input_tokens": 1000,
            "cached_tokens": 200,
            "output_tokens": 50,
            "effective_tokens": 850,
            "call_count": 1,
        }
        normal_record = {
            "thread_id": "thread-4",
            "session_id": "thread-4",
            "turn_id": "turn-normal",
            "observed_at": observed_at,
            "input_tokens": 100,
            "cached_tokens": 40,
            "output_tokens": 10,
            "effective_tokens": 70,
            "call_count": 1,
        }
        skipped_turn = {
            "thread_id": "thread-4",
            "session_id": "thread-4",
            "turn_id": "turn-plan",
            "observed_at": observed_at,
            "reason": "plan_mode",
        }
        write_json(state_path, {
            "version": 1,
            "records": [plan_record, normal_record],
            "skipped_turns": [skipped_turn],
        })
        write_json(ledger_path, {
            "version": 1,
            "records": [plan_record, normal_record],
        })

        with patched_env({
            "CODEX_PET_LIMIT_RINGS_TURN_USAGE_STATE": state_path,
            "CODEX_PET_LIMIT_RINGS_TURN_USAGE_LEDGER": ledger_path,
            "CODEX_PET_LIMIT_RINGS_TURN_USAGE_SUMMARY": summary_path,
        }):
            hook.sync_existing_skipped_turns()

        with open(state_path, "r", encoding="utf-8") as handle:
            state = json.load(handle)
        with open(ledger_path, "r", encoding="utf-8") as handle:
            ledger = json.load(handle)
        with open(summary_path, "r", encoding="utf-8") as handle:
            summary = json.load(handle)

        assert [record["turn_id"] for record in state["records"]] == ["turn-normal"]
        assert [record["turn_id"] for record in ledger["records"]] == ["turn-normal"]
        assert state["skipped_turns"][0]["turn_id"] == "turn-plan"
        assert summary["record_count"] == 1
        assert summary["today"]["effective_tokens"] == 70
        assert summary["latest_session"]["effective_tokens"] == 70


def test_prune_skipped_turns_ignores_malformed_rows(hook):
    pruned = hook.prune_skipped_turns([
        "bad-row",
        {"thread_id": "thread-3", "turn_id": "turn-plan", "observed_at": 9_999_999_999.0},
    ])

    assert len(pruned) == 1
    assert pruned[0]["thread_id"] == "thread-3"


def main():
    hook = load_hook()
    test_reads_plan_mode_from_transcript(hook)
    test_detects_plan_mode_payload(hook)
    test_turn_mode_uses_explicit_transcript_path(hook)
    test_session_transcript_paths_limits_recent_candidates(hook)
    test_queue_job_preserves_transcript_path(hook)
    test_default_logs_path_prefers_active_sqlite_dir(hook)
    test_default_logs_path_falls_back_to_legacy_path(hook)
    test_skipped_turn_updates_state(hook)
    test_sync_existing_skipped_turns_rewrites_ledger_and_summary(hook)
    test_prune_skipped_turns_ignores_malformed_rows(hook)


if __name__ == "__main__":
    main()
