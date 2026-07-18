# codex-pet-limit-rings

Codex 펫 주변에 사용량 한도를 링이나 바로 표시하는 macOS 보조 앱입니다. Codex 앱 번들을 수정하지 않고, 로컬 Codex 상태와 사용량 로그만 읽어 별도 투명 오버레이 창을 그립니다.

앱은 펫 이미지를 교체하지 않습니다. Codex가 현재 띄운 펫을 그대로 쓰고, 그 주변에 사용량 표시만 얹습니다.

<img src="docs/assets/usage-bars-preview.png" alt="현재 Codex 펫 아래에 표시된 바 스타일 사용량 오버레이" width="360">

위 이미지는 실제 실행 화면 예시입니다. 펫은 Codex가 띄운 현재 펫이고, 아래 두 줄만 이 앱이 그리는 바 스타일 오버레이입니다.

## 빠른 설치

`git clone` 없이 바로 설치할 수 있습니다. 아래 명령은 필요한 설치 파일만 임시 폴더에 내려받고 설치 후 정리합니다.

```bash
curl -fsSL https://raw.githubusercontent.com/aqwsde321/codex-pet-limit-rings/main/tools/install-remote.sh | bash
```

이미 저장소를 로컬에 받은 경우:

```bash
tools/install-limit-rings.sh
```

개발 모드로 한 번만 실행:

```bash
tools/run-limit-rings.sh
```

제거:

```bash
curl -fsSL https://raw.githubusercontent.com/aqwsde321/codex-pet-limit-rings/main/tools/install-remote.sh | bash -s -- --uninstall
```

이미 저장소를 로컬에 받은 경우:

```bash
tools/uninstall-limit-rings.sh
```

## Codex에게 맡기기

이 저장소는 Codex 에이전트가 바로 설치할 수 있게 구성되어 있습니다. 처음 쓰는 사용자는 기본 설치를 추천합니다.

- 추천: 오버레이 앱만 설치
- 선택: 다른 Codex 대화에서도 이 작업 흐름을 재사용하려면 skill까지 설치

Codex에게 이렇게 요청하면 됩니다.

```text
Codex Pet Limit Rings를 설치해 줘. 가장 단순한 구성을 먼저 추천하고, Codex skill 설치 전에는 확인을 받은 뒤 오버레이 실행 상태까지 검증해 줘.
```

관련 파일:

- [AGENTS.md](AGENTS.md): 프로젝트 작업 규칙
- [skills/codex-pet-limit-rings/SKILL.md](skills/codex-pet-limit-rings/SKILL.md): 설치/검증 워크플로
- [docs/limit-rings.md](docs/limit-rings.md): 데이터와 렌더링 모델
- [docs/solutions/workflow-issues/usage-overlay-no-data-diagnosis.md](docs/solutions/workflow-issues/usage-overlay-no-data-diagnosis.md): Codex 업데이트 후 overlay 미표시 진단 순서

스킬을 로컬 Codex에 설치하려면:

```bash
tools/install-codex-skill.sh
```

## 이미지로 보는 UI

아래 이미지는 실제 실행 화면 예시입니다. 퍼센트와 리셋 시간은 사용자의 로컬 Codex 로그에 따라 바뀝니다.

### 링

<img src="docs/assets/usage-rings-preview.png" alt="링 스타일 사용량 오버레이" width="360">

새 설치의 기본 표시입니다. 가운데에는 현재 Codex 펫이 보이고, 바깥 링은 짧은 사용량 창, 안쪽 링은 주간 한도의 남은 비율을 보여 줍니다.

### 바

<img src="docs/assets/usage-bars-preview.png" alt="바 스타일 사용량 오버레이" width="360">

더 작게 보고 싶을 때 쓰는 표시입니다. 위쪽 바는 짧은 사용량 창, 아래쪽 바는 주간 한도입니다. `Display Style`을 `Bars`로 바꾸면 폭과 위치를 메뉴에서 조정할 수 있습니다.

### 메뉴

메뉴 막대 아이콘에서 오버레이 표시, 링/바 전환, 각 스타일의 위치, 바 너비, 새로고침, 종료를 제어합니다. 링과 바 위치는 따로 저장됩니다.

## 동작 방식

앱은 다음 로컬 상태를 읽습니다.

- `~/.codex/.codex-global-state.json`: 펫 표시 여부와 위치
- Codex CLI `app-server --stdio`: 현재 계정의 rate-limit snapshot
- `~/.codex/sqlite/logs_2.sqlite` 또는 legacy `~/.codex/logs_2.sqlite`: 최신 로컬 `codex.rate_limits` fallback 이벤트

펫을 닫으면 오버레이도 사라지고, 다시 켜면 따라옵니다. 여러 모니터에서도 현재 펫 위치를 기준으로 움직입니다.

## 프라이버시

앱은 로컬 파일만 읽고, OpenAI API 키나 `~/.codex/auth.json`을 읽지 않습니다. 원격 사용량 엔드포인트도 호출하지 않습니다.

전역 마우스 이벤트 모니터링을 끄려면:

```bash
CODEX_PET_LIMIT_RINGS_NO_MOUSE_MONITOR=1 tools/install-limit-rings.sh
```

## 프로젝트 구조

```text
tools/
  codex-pet-limit-rings.swift      macOS 보조 앱
  install-remote.sh                clone 없는 원라인 설치
  install-limit-rings.sh           빌드/설치/로그인 항목 시작
  uninstall-limit-rings.sh         앱과 로그인 항목 제거
  cleanup-legacy-turn-usage.sh     이전 릴리스의 hook 상태 정리
  run-limit-rings.sh               개발 실행

skills/codex-pet-limit-rings/
  SKILL.md                         Codex 에이전트용 작업 흐름

docs/
  assets/                          README 이미지
  limit-rings.md                   구현 계약
```

## 개발

```bash
tools/build-limit-rings.sh
swiftc tools/codex-pet-limit-rings.swift -o tmp/codex-pet-limit-rings -framework AppKit -lsqlite3
tmp/codex-pet-limit-rings --preview tmp/limit-rings-preview.png --size 164
bash -n tools/*.sh
tools/test-limit-rings-usage.sh
tools/test-cleanup-legacy-turn-usage.sh
```

## 라이선스

MIT. 자세한 내용은 [LICENSE](LICENSE)를 참고하세요.
