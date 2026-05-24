#!/usr/bin/env python3
import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path


def main():
    args = parse_args()
    state_path = args.state.expanduser()
    state = read_json(state_path)
    records = [record for record in state.get("records", []) if isinstance(record, dict)]
    records = sorted(records, key=lambda item: item.get("observed_at") or 0, reverse=True)

    if args.turn:
        matches = [record for record in records if matches_turn_selector(record, args.turn)]
        if not matches:
            print(f"inspect-turn-usage: no turn matched {args.turn!r} in {state_path}", file=sys.stderr)
            return 1
        if len(matches) > 1 and not args.json:
            print(f"inspect-turn-usage: {len(matches)} turns matched {args.turn!r}; showing newest", file=sys.stderr)
        record = matches[0]
    else:
        if not records:
            print(f"inspect-turn-usage: no records in {state_path}", file=sys.stderr)
            return 1
        record = records[0]

    if args.json:
        print(json.dumps(enriched_record(record, args.goal_tokens), indent=2, sort_keys=True))
    else:
        print_text_record(record, args.goal_tokens)
    return 0


def parse_args():
    parser = argparse.ArgumentParser(
        description="Inspect raw turn usage counters collected by codex-pet-limit-rings."
    )
    parser.add_argument(
        "--latest",
        action="store_true",
        help="Show the newest record. This is the default when --turn is omitted.",
    )
    parser.add_argument(
        "--turn",
        help="Full turn id, turn suffix, or a menu label like W3/5e54/be08.",
    )
    parser.add_argument(
        "--goal-tokens",
        type=int,
        help="Compare the inspected Used value with a goal tokensUsed number.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print the enriched record as JSON.",
    )
    parser.add_argument(
        "--state",
        type=Path,
        default=default_state_path(),
        help="Path to turn-usage.json.",
    )
    return parser.parse_args()


def default_state_path():
    override = os.environ.get("CODEX_PET_LIMIT_RINGS_TURN_USAGE_STATE")
    if override:
        return Path(override)
    codex_home = Path(os.environ.get("CODEX_HOME", "~/.codex")).expanduser()
    return codex_home / "codex-pet-limit-rings" / "turn-usage.json"


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
    except FileNotFoundError:
        print(f"inspect-turn-usage: missing state file {path}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as error:
        print(f"inspect-turn-usage: invalid JSON in {path}: {error}", file=sys.stderr)
        sys.exit(1)
    return value if isinstance(value, dict) else {}


def matches_turn_selector(record, selector):
    parts = [part for part in selector.split("/") if part]
    turn_selector = parts[-1] if parts else selector
    thread_selector = None
    if len(parts) >= 2 and not parts[-2].startswith("W"):
        thread_selector = parts[-2]

    turn_id = str(record.get("turn_id") or "")
    thread_id = str(record.get("thread_id") or record.get("session_id") or "")
    if not turn_id_matches(turn_id, turn_selector):
        return False
    if thread_selector and not id_matches(thread_id, thread_selector):
        return False
    return True


def turn_id_matches(turn_id, selector):
    return id_matches(turn_id, selector)


def id_matches(value, selector):
    return bool(value) and bool(selector) and (value == selector or value.endswith(selector))


def print_text_record(record, goal_tokens):
    input_tokens = int(record.get("input_tokens") or 0)
    cached_tokens = int(record.get("cached_tokens") or 0)
    output_tokens = int(record.get("output_tokens") or 0)
    effective_tokens = effective_tokens_for_record(record)
    call_count = call_count_for_record(record)

    print(label_for_record(record))
    print(f"observed_at: {format_observed_at(record.get('observed_at'))}")
    print(f"used: {effective_tokens} = max(0, {input_tokens} - {cached_tokens}) + {output_tokens}")
    if goal_tokens is not None:
        delta = effective_tokens - goal_tokens
        print(f"goal_compare: hook-used {effective_tokens} vs goal {goal_tokens} delta {delta:+d}")
    print(f"calls: {call_count}")
    print(f"thread_id: {record.get('thread_id') or ''}")
    if record.get("session_id"):
        print(f"session_id: {record.get('session_id')}")
    print(f"turn_id: {record.get('turn_id') or ''}")

    calls = [call for call in record.get("calls", []) if isinstance(call, dict)]
    if calls:
        print("call_details:")
        for index, call in enumerate(calls, start=1):
            call_input = int(call.get("input_tokens") or 0)
            call_cached = int(call.get("cached_tokens") or 0)
            call_output = int(call.get("output_tokens") or 0)
            call_effective = int(call.get("effective_tokens") or effective_token_count(call_input, call_cached, call_output))
            response_id = call.get("response_id") or ""
            suffix = f" response_id={response_id}" if response_id else ""
            print(
                f"  {index}: used={call_effective} input={call_input} "
                f"cached={call_cached} output={call_output}{suffix}"
            )


def enriched_record(record, goal_tokens):
    value = dict(record)
    value["computed_effective_tokens"] = effective_tokens_for_record(record)
    value["computed_call_count"] = call_count_for_record(record)
    value["label"] = label_for_record(record)
    if goal_tokens is not None:
        value["goal_tokens"] = goal_tokens
        value["goal_delta_tokens"] = effective_tokens_for_record(record) - goal_tokens
    return value


def effective_tokens_for_record(record):
    effective_tokens = record.get("effective_tokens")
    if effective_tokens is not None:
        return int(effective_tokens)
    return effective_token_count(
        int(record.get("input_tokens") or 0),
        int(record.get("cached_tokens") or 0),
        int(record.get("output_tokens") or 0),
    )


def effective_token_count(input_tokens, cached_tokens, output_tokens):
    return max(0, input_tokens - cached_tokens) + max(0, output_tokens)


def call_count_for_record(record):
    call_count = record.get("call_count")
    if isinstance(call_count, int) and call_count > 0:
        return call_count
    calls = record.get("calls")
    if isinstance(calls, list) and calls:
        return len(calls)
    return 1


def label_for_record(record):
    thread_id = str(record.get("thread_id") or record.get("session_id") or "")
    turn_id = str(record.get("turn_id") or "")
    return f"{short_id(thread_id)}/{short_id(turn_id)}"


def short_id(value):
    compact = value.replace("-", "")
    if len(compact) <= 4:
        return compact or "?"
    return compact[-4:]


def format_observed_at(value):
    if not isinstance(value, (int, float)):
        return "unknown"
    return datetime.fromtimestamp(value).isoformat(timespec="seconds")


if __name__ == "__main__":
    raise SystemExit(main())
