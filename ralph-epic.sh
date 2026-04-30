#!/bin/bash
# ralph-epic.sh — DEPRECATED. The story-task architecture replaces epics.
#
# All lifecycle management (list, add, next, set-status, abandon, etc.) has
# moved to ralph-story.sh, which is a full functional superset of this file.
#
# To convert an existing sprint from the epic/PRD format to stories:
#   ./ralph-sprint-migrate.sh [--sprint NAME] [--dry-run]
#
# The only retained command is `normalize-statuses`, which repairs legacy
# "aborted" values in epics.json before you run ralph-sprint-migrate.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPRINTS_DIR="$SCRIPT_DIR/sprints"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
EPICS_FILE="${RALPH_EPICS_FILE:-}"

fail() { echo "Error: $*" >&2; exit 1; }

get_active_sprint() {
  [ -f "$ACTIVE_SPRINT_FILE" ] || return 1
  awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE"
}

resolve_epics_file() {
  [ -n "$EPICS_FILE" ] && return 0
  local active_sprint
  active_sprint="$(get_active_sprint)" || fail "No active sprint and no RALPH_EPICS_FILE set."
  EPICS_FILE="$SPRINTS_DIR/$active_sprint/epics.json"
}

ensure_file() {
  [ -f "$EPICS_FILE" ] || fail "Missing epics file: $EPICS_FILE"
  jq -e '.epics and (.epics | type == "array")' "$EPICS_FILE" >/dev/null 2>&1 \
    || fail "Invalid epics JSON: $EPICS_FILE"
}

normalize_statuses() {
  local before_count
  before_count="$(jq '[.epics[] | select(.status == "aborted")] | length' "$EPICS_FILE")"
  if [ "$before_count" -eq 0 ]; then
    echo "No legacy statuses to normalize."
    return 0
  fi

  local tmp_file
  tmp_file="$(mktemp)"
  jq '.epics = (.epics | map(if .status == "aborted" then .status = "abandoned" else . end))' \
    "$EPICS_FILE" > "$tmp_file"
  mv "$tmp_file" "$EPICS_FILE"

  echo "Normalized $before_count epic(s): aborted → abandoned"
}

_deprecated() {
  local cmd="$1"
  echo "ralph-epic.sh: '$cmd' is deprecated." >&2
  echo "  Use ralph-story.sh for story management." >&2
  echo "  To migrate this sprint: ./ralph-sprint-migrate.sh [--dry-run]" >&2
  exit 1
}

main() {
  require_cmd jq

  local cmd="${1:-}"
  case "$cmd" in
    normalize-statuses)
      resolve_epics_file
      ensure_file
      normalize_statuses
      ;;
    ""|help|-h|--help)
      cat <<'EOF'
ralph-epic.sh is DEPRECATED — use ralph-story.sh for story management.

To migrate an existing sprint (epics.json → stories.json + story.json):
  ./ralph-sprint-migrate.sh [--sprint NAME] [--dry-run]

Retained command:
  normalize-statuses    Fix legacy "aborted" → "abandoned" before migration
EOF
      ;;
    *)
      _deprecated "$cmd"
      ;;
  esac
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

main "$@"
