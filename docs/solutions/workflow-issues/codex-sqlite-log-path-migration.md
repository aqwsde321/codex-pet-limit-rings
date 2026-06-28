---
title: Codex SQLite 로그 경로 이동 대응
date: 2026-06-16
category: workflow-issues
module: codex-pet-limit-rings
problem_type: debugging
component: local-usage-log
severity: medium
tags: [codex, sqlite, usage-tracking, stop-hook, log-format, usage-toast]
related_files:
  - tools/codex-pet-limit-rings.swift
  - tools/codex-turn-usage-stop-hook.py
  - tools/test-limit-rings-usage.swift
  - tools/test-turn-usage-stop-hook.py
  - docs/recent-usage.md
---

## Problem

Codex 업데이트 이후 Codex Pet Limit Rings가 최신 토큰 사용량을 잘 잡지 못했다. 앱과 선택 Stop hook은 local SQLite 로그를 읽어 `codex.rate_limits`와 `response.completed` usage를 계산하는데, 새 Codex가 활성 로그 DB를 기존 root 경로가 아닌 `~/.codex/sqlite/logs_2.sqlite`에 쓰기 시작했다.

## Symptoms

- `~/.codex/logs_2.sqlite`는 더 이상 최신 턴까지 갱신되지 않았다.
- `~/.codex/sqlite/logs_2.sqlite`는 최신 `codex_api::endpoint::responses_websocket` 행을 포함했다.
- 2026-06-16 기준으로는 `response.completed` usage 파서 조건이 최신 DB에서 사용량 행을 잡았으므로, 주된 문제는 JSON 포맷 변경이 아니라 기본 DB 경로 선택이었다.
- `Track Turn Usage`가 꺼져 있으면 최근 턴 사용량 폴링과 Stop hook 수집은 설계상 동작하지 않는다.

## Root Cause

기존 기본 경로 선택은 `~/.codex/logs_2.sqlite`가 존재하면 그 파일을 우선했다. Codex 업데이트 후 legacy 파일이 남아 있는 상태에서 실제 활성 DB가 `~/.codex/sqlite/logs_2.sqlite`로 이동하면서, 앱과 hook 모두 오래된 DB를 계속 읽었다.

## Solution

- 앱과 Stop hook의 기본 로그 경로 선택에 `~/.codex/sqlite/logs_2.sqlite` 후보를 추가했다.
- `sqlite/logs_2.sqlite`와 legacy `logs_2.sqlite`가 모두 있으면 수정 시간이 더 최신인 파일을 선택한다.
- `logs_2.sqlite`가 없으면 `sqlite/logs_1.sqlite`, legacy `logs_1.sqlite` 순서로 fallback한다.
- 설치된 앱과 hook 사본을 갱신했다.

## Verification

다음 검증을 통과했다.

```bash
bash -n tools/*.sh
tools/test-limit-rings-usage.sh
python3 tools/test-turn-usage-stop-hook.py
swiftc tools/codex-pet-limit-rings.swift -o tmp/codex-pet-limit-rings -framework AppKit -lsqlite3
tmp/codex-pet-limit-rings --preview tmp/limit-rings-preview.png --size 164
git diff --check
```

설치 후 확인:

```bash
pgrep -fl CodexPetLimitRings
launchctl print "gui/$(id -u)/com.codex-pet.limit-rings"
```

## 2026-06-29 Update: Usage Log Format Drift

Codex 26.623.30605에서는 최신 턴 사용량 토스트가 다시 뜨지 않았다. 이번에는 활성 DB 경로가 아니라 로그 포맷이 바뀐 것이 원인이었다.

증상:

- `response.completed`와 JSON `usage.input_tokens` 조건으로는 최신 턴이 잡히지 않았다.
- 최신 DB에는 `codex_core::session::turn` target의 `post sampling token usage turn_id=... total_usage_tokens=...` 행이 계속 들어왔다.
- 단순히 `codex.turn.token_usage.input_tokens=` 문자열만 검색하면 Codex가 터미널 출력과 assistant 메시지까지 로그로 남겨 가짜 매칭이 생길 수 있었다.

해결:

- SQLite fallback 쿼리에 `target = 'codex_core::session::turn'`와 `post sampling token usage turn_id=`/`total_usage_tokens=` 조건을 추가했다.
- `total_usage_tokens`는 해당 turn의 누적값이므로, 같은 turn의 이전 샘플과 합산하지 않고 최신 행 하나만 사용한다.
- 기존 JSON `response.completed` usage 파서는 유지해서 이전 포맷과 호환한다.

검증:

```bash
tools/test-limit-rings-usage.sh
bash -n tools/*.sh
swiftc tools/codex-pet-limit-rings.swift -o tmp/codex-pet-limit-rings -framework AppKit -lsqlite3
tmp/codex-pet-limit-rings --preview tmp/limit-rings-preview.png --size 164
tools/install-limit-rings.sh
pgrep -fl CodexPetLimitRings
launchctl print "gui/$(id -u)/com.codex-pet.limit-rings"
```

## Prevention

- Codex local DB 경로를 다시 다룰 때는 root `~/.codex/*.sqlite`만 보지 말고 `~/.codex/sqlite/*.sqlite`도 확인한다.
- usage 파서 변경 전에 최신 DB에서 `response.completed` JSON usage와 `post sampling token usage` 누적 usage 중 어느 포맷이 실제로 들어오는지 먼저 확인한다.
- `codex.turn.token_usage.*` 문자열 검색은 터미널 출력 로그를 다시 매칭할 수 있으므로, 실제 trace target과 `post sampling token usage` 문구까지 함께 좁힌다.
- Stop hook은 앱 설치와 별도로 복사되는 사본이 있으므로, hook 관련 수정 후 `tools/install-turn-usage-hook.sh`로 설치 사본까지 갱신한다.
- 기존 Codex 세션은 hook 설정과 코드를 시작 시점에 읽을 수 있으므로, hook 수정 후 새 세션에서 재확인한다.

## Reuse Checklist

- 최신 로그 DB의 실제 경로와 수정 시간을 확인했는가?
- legacy DB가 존재하지만 stale 상태인지 확인했는가?
- 최신 턴 사용량이 JSON `response.completed` 포맷인지 `post sampling token usage` 포맷인지 확인했는가?
- 앱과 Stop hook 양쪽의 경로 선택이 같은가?
- `Track Turn Usage` 설정이 켜져 있는지 확인했는가?
- 설치된 앱과 hook 사본이 저장소 수정본과 일치하는가?
