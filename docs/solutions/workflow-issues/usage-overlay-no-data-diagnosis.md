---
title: Codex 업데이트 후 usage overlay 미표시 진단
date: 2026-07-10
updated: 2026-07-19
category: workflow-issues
module: codex-pet-limit-rings
problem_type: debugging
component: rate-limit-overlay
severity: high
tags: [codex, app-server, sqlite, rate-limit, usage-overlay, pet-frame, launch-agent]
related_files:
  - tools/codex-pet-limit-rings.swift
  - tools/test-limit-rings-usage.swift
  - tools/install-limit-rings.sh
  - docs/limit-rings.md
---

## Problem

Codex 업데이트 뒤 앱은 실행 중이지만 링·바가 `NO DATA`를 표시하거나 오버레이 전체가 사라졌다. `NO DATA` 표시 여부로 usage 공급 경로와 팻 위치 경로를 먼저 분리해야 했다.

## Diagnosis Order

### 1. 증상 범위를 분리한다

- `NO DATA`가 보이면 rate-limit snapshot 경로를 조사한다.
- `NO DATA`도 보이지 않으면 `electron-avatar-overlay-open`과 `electron-avatar-overlay-bounds`를 먼저 확인한다. 팻 프레임을 읽지 못하면 오버레이 패널 자체가 숨겨지므로 usage 공급 경로가 정상이어도 아무것도 보이지 않는다.

Codex 자체 usage 화면에 값이 있으면 이를 기대값으로 기록한다. 예를 들어 Codex 화면의 `99% 남음`은 app-server의 `usedPercent: 1`과 대응한다.

### 2. 실제 설치본과 실행 상태를 확인한다

```bash
launchctl print "gui/$(id -u)/com.codex-pet.limit-rings"
ls -lhT "$HOME/Applications/CodexPetLimitRings.app/Contents/MacOS/CodexPetLimitRings"
```

확인 항목:

- LaunchAgent가 `running`인가?
- 설치 바이너리 수정 시간이 저장소 수정 이후인가?
- 저장소만 수정하고 `tools/install-limit-rings.sh`를 생략하지 않았는가?

### 3. app-server CLI 탐색을 확인한다

LaunchAgent 기본 PATH는 보통 `/usr/bin:/bin:/usr/sbin:/sbin`이다. 대화형 shell에서 `codex`가 보여도 LaunchAgent가 Homebrew 경로를 찾는다고 가정하면 안 된다.

```bash
command -v codex
readlink /opt/homebrew/bin/codex
ls -l \
  /Applications/Codex.app/Contents/Resources/codex \
  "$HOME/Applications/Codex.app/Contents/Resources/codex" \
  /opt/homebrew/bin/codex \
  /usr/local/bin/codex 2>/dev/null
```

`AppServerLimitStateReader.findCodexCLI()` 후보와 실제 실행 파일 위치를 대조한다. Codex 앱 이름·설치 위치가 바뀌거나 bundle 내부 CLI가 제거되면 기존 후보가 모두 실패할 수 있다.

### 4. app-server 응답을 독립 재현한다

`codex app-server --stdio`를 실행하고 stdin을 열린 상태로 유지한 뒤 아래 요청을 한 줄씩 보낸다.

```json
{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-pet-limit-rings","version":"0"},"capabilities":{"experimentalApi":true}}}
{"id":2,"method":"account/rateLimits/read"}
```

판정:

- `id: 2` 결과에 `rateLimits.primary/secondary`와 `usedPercent`, `windowDurationMins`, `resetsAt`이 있으면 endpoint와 decode 모델은 우선 정상으로 본다.
- 응답 필드와 `AppServerRateLimitReadResponse`를 직접 대조한다.
- shell pipe로 요청을 한꺼번에 넣고 즉시 EOF를 보내면 비동기 응답 전에 프로세스가 끝날 수 있다. 이 결과만으로 API 변경이나 무응답을 단정하지 않는다.

### 5. SQLite fallback을 별도로 확인한다

활성 DB 후보의 수정 시간과 크기를 먼저 본다.

```bash
ls -lhT "$HOME/.codex/logs_2.sqlite" "$HOME/.codex/sqlite/logs_2.sqlite" 2>/dev/null
```

그다음 실제 rate-limit 행을 찾는다.

```bash
sqlite3 "$HOME/.codex/logs_2.sqlite" "
SELECT datetime(ts, 'unixepoch', 'localtime'), target,
       substr(feedback_log_body, 1, 1200)
FROM logs INDEXED BY idx_logs_ts
WHERE feedback_log_body LIKE '%codex.rate_limits%'
ORDER BY ts DESC, ts_nanos DESC, id DESC
LIMIT 5;
"
```

판정:

- broad 검색도 0행이면 해당 DB는 현재 rate-limit fallback을 제공하지 않는다.
- broad 검색은 잡히지만 앱의 exact SQL이 0행이면 target 또는 body prefix가 변경된 것이다.
- 행은 잡히지만 표시되지 않으면 JSON decode, window duration, reset 만료 검사를 확인한다.
- root DB와 `sqlite/` DB가 모두 있으면 수정 시간이 최신인 파일이 실제 활성 DB인지 확인한다.

### 6. 원인을 한 경로에서 재현한 뒤 수정한다

가능한 결론은 다음처럼 구분한다.

| 증거 | 원인 범위 |
|---|---|
| CLI 후보가 모두 없음 | CLI 탐색/LaunchAgent 환경 |
| app-server 응답 필드 변경 | request 또는 decode 모델 |
| app-server 정상, SQLite 0행 | app-server 실행 경로만 수정 |
| app-server 실패, SQLite target/prefix 변경 | fallback SQL/파서 |
| 저장소 정상, 설치본 오래됨 | 설치/재시작 누락 |

두 경로가 동시에 실패했다는 증거 없이 app-server와 SQLite를 함께 수정하지 않는다.

## 2026-07-10 Incident

Codex CLI `0.142.0` 업데이트 후 overlay가 `NO DATA` 상태가 됐다.

확인 결과:

- `account/rateLimits/read`는 정상 응답했고 Codex 자체 화면의 99%/100%와 일치했다.
- 최신 `~/.codex/logs_2.sqlite`에는 `codex.rate_limits` 행이 없었다.
- `/Applications/Codex.app/Contents/Resources/codex`와 `~/Applications/Codex.app/Contents/Resources/codex`가 존재하지 않았다.
- 실제 CLI는 `/opt/homebrew/bin/codex`에 있었다.
- LaunchAgent PATH에는 `/opt/homebrew/bin`이 없었다.

따라서 app-server CLI 탐색 실패 후 빈 SQLite fallback으로 내려간 것이 원인이었다. CLI 후보에 `/opt/homebrew/bin/codex`와 `/usr/local/bin/codex`를 추가하고 회귀 테스트를 남겼다.

## 2026-07-19 Incident: 오버레이 전체 미표시

Codex `26.715.31925` 업데이트 뒤 링·바뿐 아니라 `NO DATA`도 보이지 않았다.

확인 결과:

- 설치 앱과 LaunchAgent는 실행 중이었다.
- `account/rateLimits/read`는 정상 응답했다.
- `electron-avatar-overlay-open`은 `true`였다.
- 활성 `electron-avatar-overlay-bounds`에는 `x`, `y`, `displayBounds`, `displayId`, `placement`만 있고 기존 `width`, `height`, `mascot`이 없었다.
- `PetFrameReader`는 기존 필드를 모두 필수로 검사해 `nil`을 반환했고, `LimitRingsApp.updateFrame()`은 패널을 숨겼다.
- 업데이트된 Codex 번들은 `x`/`y`를 팻 anchor로 저장하지만 크기는 생략했다. 같은 상태 파일의 기존 상세 bounds와 실제 렌더에서 팻 크기 `80x87`을 확인했다.

따라서 usage 조회가 아니라 팻 프레임 schema 호환 문제였다. 기존 상세 bounds는 그대로 지원하고, anchor-only bounds는 `x`/`y`와 `80x87` 크기로 복원하도록 수정했다. 초기 `112x121` 추정은 팻 하단을 34포인트 낮게 계산했고, 주간 값이 없을 때 primary 바가 둘째 슬롯 높이로 내려가는 21포인트가 더해져 큰 간격이 생겼다. 팻 프레임과 단일 바 위치 회귀 테스트를 추가했다.

같은 시점에 Codex 팻의 대화 목록도 비어 있었지만 companion app과는 별도 문제였다. [공식 Pets 문서](https://learn.chatgpt.com/docs/pets?surface=app)는 둘 이상의 채팅에 activity가 있을 때 tray에서 채팅을 선택할 수 있다고 설명한다. 당시 로그에는 복수 conversation 이벤트가 있었지만 `avatarOverlay` renderer는 `unknown conversation`과 `Conversation state not found`를 반복했다. 동일 오류는 이전 로그에도 있어 이번 빌드가 최초 원인이라고 단정하지 않는다. 이 앱은 투명한 클릭 통과 패널만 추가하므로 Codex의 activity tray 상태를 변경하지 않는다.

## Verification

```bash
tools/test-limit-rings-usage.sh
bash -n tools/*.sh
swiftc -module-cache-path tmp/swift-module-cache \
  tools/codex-pet-limit-rings.swift \
  -o tmp/codex-pet-limit-rings \
  -framework AppKit -lsqlite3
tmp/codex-pet-limit-rings --preview tmp/limit-rings-preview.png --size 164
tools/install-limit-rings.sh
launchctl print "gui/$(id -u)/com.codex-pet.limit-rings"
```

설치 후 최소 한 번의 20초 poll이 지나 app-server child 실행과 퍼센트 표시를 확인한다.

## Reuse Checklist

- Codex 자체 usage 화면의 기대 퍼센트를 기록했는가?
- 실행 중 설치본이 최신인가?
- LaunchAgent 환경에서 실제 Codex CLI 후보가 실행 가능한가?
- stdin을 유지한 app-server 세션에서 응답을 확인했는가?
- 활성 SQLite DB와 실제 최신 rate-limit 행을 확인했는가?
- request, decode, SQL 중 실패한 한 경로만 수정했는가?
- `NO DATA`도 없으면 팻 open 상태와 bounds 필드 형식을 확인했는가?
- 회귀 테스트, 설치, 20초 poll을 모두 검증했는가?
