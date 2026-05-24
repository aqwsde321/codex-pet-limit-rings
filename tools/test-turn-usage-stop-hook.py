#!/usr/bin/env python3
import importlib.util
import json
import os
import tempfile
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
        assert hook.turn_collaboration_mode_kind(payload) == "plan"


def test_queue_job_preserves_transcript_path(hook):
    job = hook.build_queue_job({
        "session_id": "thread-1",
        "turn_id": "turn-d",
        "transcript_path": "/tmp/rollout-test.jsonl",
    })

    assert job["transcript_path"] == "/tmp/rollout-test.jsonl"
    assert hook.queue_job_payload(job)["transcript_path"] == "/tmp/rollout-test.jsonl"


def test_skipped_turn_updates_state(hook):
    with tempfile.TemporaryDirectory() as tmpdir:
        state_path = Path(tmpdir) / "turn-usage.json"
        old_value = os.environ.get("CODEX_PET_LIMIT_RINGS_TURN_USAGE_STATE")
        os.environ["CODEX_PET_LIMIT_RINGS_TURN_USAGE_STATE"] = str(state_path)
        try:
            hook.append_skipped_turn({
                "session_id": "thread-2",
                "turn_id": "turn-plan",
                "collaboration_mode_kind": "plan",
            })
        finally:
            if old_value is None:
                os.environ.pop("CODEX_PET_LIMIT_RINGS_TURN_USAGE_STATE", None)
            else:
                os.environ["CODEX_PET_LIMIT_RINGS_TURN_USAGE_STATE"] = old_value

        with open(state_path, "r", encoding="utf-8") as handle:
            state = json.load(handle)
        skipped_turn = state["skipped_turns"][0]
        assert skipped_turn["thread_id"] == "thread-2"
        assert skipped_turn["turn_id"] == "turn-plan"
        assert skipped_turn["reason"] == "plan_mode"


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
    test_queue_job_preserves_transcript_path(hook)
    test_skipped_turn_updates_state(hook)
    test_prune_skipped_turns_ignores_malformed_rows(hook)


if __name__ == "__main__":
    main()
