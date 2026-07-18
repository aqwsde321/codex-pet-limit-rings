---
title: Codex SQLite 로그 경로 이동 대응
date: 2026-06-16
category: workflow-issues
module: codex-pet-limit-rings
problem_type: debugging
component: rate-limit-overlay
severity: medium
tags: [codex, sqlite, rate-limit, log-path]
related_files:
  - tools/codex-pet-limit-rings.swift
  - tools/test-limit-rings-usage.swift
  - docs/limit-rings.md
---

## Problem

Codex가 활성 SQLite 로그를 `~/.codex/sqlite/` 아래로 옮긴 뒤, legacy DB가 남아 있으면 앱이 오래된 rate-limit 이벤트를 읽을 수 있었다.

## Symptoms

- `~/.codex/logs_2.sqlite`는 더 이상 최신 로그로 갱신되지 않았다.
- `~/.codex/sqlite/logs_2.sqlite`는 최신 `codex.rate_limits` 행을 포함했다.

## Root Cause

기존 기본 경로 선택은 `~/.codex/logs_2.sqlite`가 존재하면 그 파일을 우선했다. Codex 업데이트 후 legacy 파일이 남아 있는 상태에서 실제 활성 DB가 `~/.codex/sqlite/logs_2.sqlite`로 이동하면서 앱이 오래된 DB를 계속 읽었다.

## Solution

- `sqlite/logs_2.sqlite`와 legacy `logs_2.sqlite`가 모두 있으면 수정 시간이 더 최신인 파일을 선택한다.
- `logs_2.sqlite`가 없으면 `sqlite/logs_1.sqlite`, legacy `logs_1.sqlite` 순서로 fallback한다.
- 설치된 앱을 갱신했다.

## Verification

다음 검증을 통과했다.

```bash
bash -n tools/*.sh
tools/test-limit-rings-usage.sh
swiftc tools/codex-pet-limit-rings.swift -o tmp/codex-pet-limit-rings -framework AppKit -lsqlite3
tmp/codex-pet-limit-rings --preview tmp/limit-rings-preview.png --size 164
git diff --check
```

설치 후 확인:

```bash
pgrep -fl CodexPetLimitRings
launchctl print "gui/$(id -u)/com.codex-pet.limit-rings"
```

## Prevention

- Codex local DB 경로를 다시 다룰 때는 root `~/.codex/*.sqlite`만 보지 말고 `~/.codex/sqlite/*.sqlite`도 확인한다.
- 파일 존재 여부만으로 선택하지 말고 수정 시간을 비교한다.
- fallback SQL을 바꾸기 전 최신 DB에 실제 `codex.rate_limits` 행이 있는지 확인한다.

## Reuse Checklist

- 최신 로그 DB의 실제 경로와 수정 시간을 확인했는가?
- legacy DB가 존재하지만 stale 상태인지 확인했는가?
- 최신 DB에 현재 `codex.rate_limits` 행이 있는가?
- 설치된 앱이 저장소 수정본과 일치하는가?
