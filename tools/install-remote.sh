#!/usr/bin/env bash
set -euo pipefail

REF="${CODEX_PET_LIMIT_RINGS_REF:-main}"
RAW_BASE="${CODEX_PET_LIMIT_RINGS_RAW_BASE:-https://raw.githubusercontent.com/aqwsde321/codex-pet-limit-rings/$REF}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-pet-limit-rings.XXXXXX")"
WITH_SKILL=0
UNINSTALL=0

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage: install-remote.sh [--with-skill] [--uninstall]

Downloads only the files needed for installation into a temporary directory.
No git clone is required.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-skill)
      WITH_SKILL=1
      ;;
    --uninstall)
      UNINSTALL=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "install-remote.sh: unknown argument $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

download_file() {
  local path="$1"
  local destination="$TMP_ROOT/$path"
  mkdir -p "$(dirname "$destination")"
  curl -fsSL "$RAW_BASE/$path" -o "$destination"
}

if [[ "$UNINSTALL" == "1" ]]; then
  download_file "tools/uninstall-limit-rings.sh"
  download_file "tools/cleanup-legacy-turn-usage.sh"
  chmod +x "$TMP_ROOT/tools/"*.sh
  "$TMP_ROOT/tools/uninstall-limit-rings.sh"
  exit 0
fi

download_file "tools/CodexPetLimitRings-Info.plist"
download_file "tools/build-limit-rings.sh"
download_file "tools/codex-pet-limit-rings.swift"
download_file "tools/install-limit-rings.sh"
download_file "tools/cleanup-legacy-turn-usage.sh"


if [[ "$WITH_SKILL" == "1" ]]; then
  download_file "skills/codex-pet-limit-rings/SKILL.md"
  download_file "skills/codex-pet-limit-rings/agents/openai.yaml"
  download_file "tools/install-codex-skill.sh"
fi

chmod +x "$TMP_ROOT/tools/"*.sh
"$TMP_ROOT/tools/install-limit-rings.sh"


if [[ "$WITH_SKILL" == "1" ]]; then
  "$TMP_ROOT/tools/install-codex-skill.sh"
fi
