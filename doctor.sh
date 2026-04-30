#!/bin/bash
# Ralph doctor - sanity checks for running Ralph in a project

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CODEX_BIN="${CODEX_BIN:-codex}"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROMPT_FILE="$SCRIPT_DIR/prompt.md"
ACTIVE_PRD_FILE="$SCRIPT_DIR/.active-prd"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
SPRINTS_DIR="$SCRIPT_DIR/sprints"
LEGACY_ARCHIVE_DIR="$SCRIPT_DIR/archive"

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

echo "Ralph doctor"
echo "ralph dir: $SCRIPT_DIR"

require_cmd git
require_cmd jq
require_cmd "$CODEX_BIN"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "Not inside a git repository. Run this from within your project repo."
fi

if [ ! -f "$PROMPT_FILE" ]; then
  fail "Missing $PROMPT_FILE"
fi

if grep -q '{{PRD_FILE}}' "$PROMPT_FILE" 2>/dev/null; then
  echo "WARN: prompt.md still contains unfilled placeholders ({{PRD_FILE}})"
fi

SPRINT_TEST_FILE="$SCRIPT_DIR/ralph-sprint-test.sh"
if [ ! -f "$SPRINT_TEST_FILE" ]; then
  echo "WARN: ralph-sprint-test.sh not found — sprint regression gate will be skipped at commit time."
  echo "      Copy $SCRIPT_DIR/ralph-sprint-test.sh.example to ralph-sprint-test.sh and customize."
fi

if [ ! -f "$PRD_FILE" ]; then
  echo "WARN: Missing $PRD_FILE"
  echo "      Create it (or copy from prd.json.example) before running ralph.sh."
fi

if [ -f "$ACTIVE_SPRINT_FILE" ]; then
  ACTIVE_SPRINT="$(awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE" || true)"
  if [ -n "${ACTIVE_SPRINT:-}" ]; then
    STORIES_FILE="$SPRINTS_DIR/$ACTIVE_SPRINT/stories.json"
    EPICS_FILE="$SPRINTS_DIR/$ACTIVE_SPRINT/epics.json"
    if [ -f "$STORIES_FILE" ]; then
      echo "OK: active sprint '$ACTIVE_SPRINT' uses story-task format (stories.json)"
    elif [ -f "$EPICS_FILE" ]; then
      echo "WARN: active sprint '$ACTIVE_SPRINT' still uses legacy epic format. Run ralph-sprint-migrate.sh to convert."
    else
      echo "WARN: active sprint '$ACTIVE_SPRINT' has no stories.json or epics.json: $STORIES_FILE"
    fi
  fi
fi

if [ -d "$LEGACY_ARCHIVE_DIR" ] && find "$LEGACY_ARCHIVE_DIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
  echo "WARN: Legacy Ralph archive path still contains files: $LEGACY_ARCHIVE_DIR"
  echo "      Canonical archive path is: $SCRIPT_DIR/tasks/archive"
fi

if [ -f "$ACTIVE_PRD_FILE" ]; then
  if ! jq -e '.' "$ACTIVE_PRD_FILE" >/dev/null 2>&1; then
    echo "WARN: Invalid JSON in $ACTIVE_PRD_FILE"
  else
    active_mode="$(jq -r '.mode // empty' "$ACTIVE_PRD_FILE")"
    active_epic_id="$(jq -r '.epicId // empty' "$ACTIVE_PRD_FILE")"
    active_source_path="$(jq -r '.sourcePath // empty' "$ACTIVE_PRD_FILE")"

    if [ ! -s "$PRD_FILE" ]; then
      echo "WARN: $ACTIVE_PRD_FILE exists but $PRD_FILE is missing/empty."
    fi

    if [ -n "$active_source_path" ] && [ ! -f "$WORKSPACE_ROOT/$active_source_path" ] && [ ! -f "$active_source_path" ]; then
      echo "WARN: Active PRD sourcePath does not exist: $active_source_path"
    fi

    if [ "$active_mode" = "epic" ] && [ -n "$active_epic_id" ] && [ -f "${EPICS_FILE:-}" ]; then
      sprint_active_epic_id="$(jq -r '.activeEpicId // empty' "$EPICS_FILE" 2>/dev/null || true)"
      if [ -n "$sprint_active_epic_id" ] && [ "$sprint_active_epic_id" != "$active_epic_id" ]; then
        echo "WARN: Active epic mismatch: .active-prd=$active_epic_id, epics.json.activeEpicId=$sprint_active_epic_id"
      fi
    fi
    if [ "$active_mode" = "story" ] && [ -n "${STORIES_FILE:-}" ] && [ -f "$STORIES_FILE" ]; then
      sprint_active_story_id="$(jq -r '.activeStoryId // empty' "$STORIES_FILE" 2>/dev/null || true)"
      active_story_id_prd="$(jq -r '.storyId // empty' "$ACTIVE_PRD_FILE" 2>/dev/null || true)"
      if [ -n "$sprint_active_story_id" ] && [ -n "$active_story_id_prd" ] && [ "$sprint_active_story_id" != "$active_story_id_prd" ]; then
        echo "WARN: Active story mismatch: .active-prd storyId=$active_story_id_prd, stories.json.activeStoryId=$sprint_active_story_id"
      fi
    fi
  fi
fi

if ! "$CODEX_BIN" exec --help >/dev/null 2>&1; then
  fail "Codex exec help failed. Check your Codex installation."
fi

if "$CODEX_BIN" --yolo exec --help 2>&1 | grep -qi "unexpected argument '--yolo'"; then
  echo "WARN: Your Codex does not support --yolo; ralph.sh will use a safe fallback."
else
  echo "OK: codex --yolo available"
fi

echo "OK: prerequisites present"
