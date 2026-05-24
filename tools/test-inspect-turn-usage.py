#!/usr/bin/env python3
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSPECT_PATH = ROOT / "tools" / "inspect-turn-usage.py"


def write_json(path, value):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, separators=(",", ":"), sort_keys=True)
        handle.write("\n")


def run_inspect(*args):
    return subprocess.run(
        [sys.executable, str(INSPECT_PATH), *args],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def test_latest_text_output():
    with tempfile.TemporaryDirectory() as tmpdir:
        state_path = Path(tmpdir) / "turn-usage.json"
        now = time.time()
        write_json(state_path, {
            "version": 1,
            "records": [
                {
                    "thread_id": "thread-older",
                    "turn_id": "turn-older",
                    "observed_at": now - 10,
                    "input_tokens": 100,
                    "cached_tokens": 40,
                    "output_tokens": 10,
                },
                {
                    "thread_id": "thread-newest",
                    "session_id": "thread-newest",
                    "turn_id": "turn-newest",
                    "observed_at": now,
                    "input_tokens": 1000,
                    "cached_tokens": 200,
                    "output_tokens": 50,
                    "effective_tokens": 850,
                    "calls": [
                        {
                            "input_tokens": 600,
                            "cached_tokens": 100,
                            "output_tokens": 30,
                            "effective_tokens": 530,
                            "response_id": "resp_a",
                        },
                        {
                            "input_tokens": 400,
                            "cached_tokens": 100,
                            "output_tokens": 20,
                            "effective_tokens": 320,
                            "response_id": "resp_b",
                        },
                    ],
                },
            ],
        })

        result = run_inspect("--state", str(state_path), "--latest", "--goal-tokens", "800")

    assert "used: 850 = max(0, 1000 - 200) + 50" in result.stdout
    assert "goal_compare: hook-used 850 vs goal 800 delta +50" in result.stdout
    assert "calls: 2" in result.stdout
    assert "response_id=resp_a" in result.stdout


def test_turn_selector_json_output():
    with tempfile.TemporaryDirectory() as tmpdir:
        state_path = Path(tmpdir) / "turn-usage.json"
        write_json(state_path, {
            "version": 1,
            "records": [
                {
                    "thread_id": "019e34ed-52bd-79b3-8391-b53fc2975e54",
                    "turn_id": "019e5918-309b-7421-8e0b-123f1406be08",
                    "observed_at": time.time(),
                    "input_tokens": 100,
                    "cached_tokens": 40,
                    "output_tokens": 10,
                },
            ],
        })

        result = run_inspect("--state", str(state_path), "--turn", "W3/5e54/be08", "--json")

    payload = json.loads(result.stdout)
    assert payload["label"] == "5e54/be08"
    assert payload["computed_effective_tokens"] == 70
    assert payload["computed_call_count"] == 1


def main():
    test_latest_text_output()
    test_turn_selector_json_output()
    print("inspect-turn-usage tests passed")


if __name__ == "__main__":
    main()
