#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$WORKSPACE_ROOT" ]; then
  WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
ACTIVE_PRD_FILE="$SCRIPT_DIR/.active-prd"
PRD_FILE="$SCRIPT_DIR/prd.json"
SPRINTS_DIR="$SCRIPT_DIR/sprints"
SPRINT_BRANCH_PREFIX="ralph/sprint"

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/ralph-status.sh

Shows the current Ralph workflow state for the active sprint/epic/story,
including loop status, branch/worktree state, and next action guidance.
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing required command: $1"
  fi
}

get_active_sprint() {
  if [ -f "$ACTIVE_SPRINT_FILE" ]; then
    awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE"
    return 0
  fi
  return 1
}

sprint_branch_name() {
  local sprint="$1"
  printf '%s/%s\n' "$SPRINT_BRANCH_PREFIX" "$sprint"
}

worktree_status() {
  if [ -n "$(git status --short 2>/dev/null)" ]; then
    printf 'dirty\n'
  else
    printf 'clean\n'
  fi
}

loop_status() {
  if pgrep -af 'scripts/ralph/ralph\.sh' >/dev/null 2>&1; then
    printf 'running\n'
  else
    printf 'stopped\n'
  fi
}

active_story_id() {
  local prd_file="$1"
  jq -r '
    (.userStories // [])
    | map(select(.passes != true))
    | sort_by(.priority, .id)
    | .[0].id // empty
  ' "$prd_file"
}

active_story_line() {
  local prd_file="$1"
  local story_id="$2"
  [ -n "$story_id" ] || return 0
  jq -r --arg id "$story_id" '
    .userStories[]
    | select(.id == $id)
    | "Active story: \(.id) (P\(.priority // 0)) - \(.title)"
  ' "$prd_file"
}

story_totals() {
  local prd_file="$1"
  jq -r '
    (.userStories // []) as $stories
    | "Stories: \(([ $stories[] | select(.passes == true) ] | length))/\(($stories | length)) passed"
  ' "$prd_file"
}

story_status_lines() {
  local prd_file="$1"
  jq -r '
    (.userStories // [])
    | sort_by(.priority, .id)
    | .[]
    | "- \(.id): \(.passes | if . then "passed" else "pending" end) - \(.title)"
  ' "$prd_file"
}

epics_file_for_sprint() {
  local sprint="$1"
  printf '%s/%s/epics.json\n' "$SPRINTS_DIR" "$sprint"
}

active_epic_id() {
  local epics_file="$1"
  jq -r '.activeEpicId // empty' "$epics_file"
}

active_epic_line() {
  local epics_file="$1"
  local epic_id="$2"
  [ -n "$epic_id" ] || return 0
  jq -r --arg id "$epic_id" '
    .epics[]
    | select(.id == $id)
    | "Active epic: \(.id) (P\(.priority // 0) E\(.effort // 0)) - \(.title)\nEpic status: \(.status // "planned")"
  ' "$epics_file"
}

next_epic_line() {
  local epics_file="$1"
  if next_id="$(RALPH_EPICS_FILE="$epics_file" "$SCRIPT_DIR/ralph-epic.sh" next-id 2>/dev/null || true)" && [ -n "$next_id" ]; then
    jq -r --arg id "$next_id" '
      .epics[]
      | select(.id == $id)
      | "Next eligible epic: \(.id) (P\(.priority // 0) E\(.effort // 0)) - \(.title)"
    ' "$epics_file"
  else
    printf 'Next eligible epic: (none)\n'
  fi
}

latest_story_commit_line() {
  local line
  line="$(git log --oneline --max-count=1 --grep='^\(feat\|fix\): \[US-' 2>/dev/null || true)"
  if [ -n "$line" ]; then
    printf 'Latest story commit: %s\n' "$line"
  fi
}

active_prd_mode_line() {
  if [ -f "$ACTIVE_PRD_FILE" ]; then
    local mode source
    mode="$(jq -r '.mode // empty' "$ACTIVE_PRD_FILE" 2>/dev/null || true)"
    source="$(jq -r '.source // empty' "$ACTIVE_PRD_FILE" 2>/dev/null || true)"
    if [ -n "$mode" ] || [ -n "$source" ]; then
      printf 'Active PRD: mode=%s source=%s\n' "${mode:-unknown}" "${source:-unknown}"
    fi
  fi
}

next_action_line() {
  local prd_file="$1"
  local epic_id="$2"
  local epics_file="$3"
  local loop_state="$4"
  local all_passed epic_status

  all_passed=false
  if jq -e '(.userStories // []) | length > 0 and all(.[]; .passes == true)' "$prd_file" >/dev/null 2>&1; then
    all_passed=true
  fi

  epic_status=""
  if [ -n "$epic_id" ]; then
    epic_status="$(jq -r --arg id "$epic_id" '.epics[] | select(.id == $id) | (.status // "")' "$epics_file" 2>/dev/null || true)"
  fi

  if [ "$all_passed" = true ] && [ "$loop_state" = "running" ]; then
    printf 'Next action: wait for Ralph to finish closeout.\n'
  elif [ "$all_passed" = true ]; then
    printf 'Next action: run ./scripts/ralph/ralph-commit.sh to close out the completed epic.\n'
  elif [ "$loop_state" = "running" ]; then
    printf 'Next action: Ralph is running; monitor the active story.\n'
  elif [ -n "$epic_id" ] && [ "$epic_status" = "active" ]; then
    printf 'Next action: run ./scripts/ralph/ralph.sh to continue the active epic.\n'
  else
    printf 'Next action: run ./scripts/ralph/ralph.sh to auto-prime and start the next eligible epic.\n'
  fi
}

main() {
  require_cmd git
  require_cmd jq
  require_cmd pgrep

  case "${1:-}" in
    -h|--help|help)
      usage
      exit 0
      ;;
    "")
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac

  local active_sprint epics_file current_branch sprint_branch loop_state worktree_state epic_id story_id
  active_sprint="$(get_active_sprint || true)"

  if [ -z "$active_sprint" ]; then
    echo "Active sprint: (none)"
    echo "Loop: $(loop_status)"
    echo "Worktree: $(worktree_status)"
    echo "Next action: run ./scripts/ralph/ralph-sprint.sh use <sprint-name>."
    exit 0
  fi

  epics_file="$(epics_file_for_sprint "$active_sprint")"
  [ -f "$epics_file" ] || fail "Missing sprint epics file: $epics_file"
  [ -f "$PRD_FILE" ] || fail "Missing PRD file: $PRD_FILE"

  current_branch="$(git branch --show-current)"
  sprint_branch="$(sprint_branch_name "$active_sprint")"
  loop_state="$(loop_status)"
  worktree_state="$(worktree_status)"
  epic_id="$(active_epic_id "$epics_file")"
  story_id="$(active_story_id "$PRD_FILE")"

  echo "Active sprint: $active_sprint"
  echo "Sprint branch: $sprint_branch"
  echo "Current branch: ${current_branch:-'(detached)'}"
  echo "Loop: $loop_state"
  echo "Worktree: $worktree_state"
  active_prd_mode_line
  if [ -n "$epic_id" ]; then
    active_epic_line "$epics_file" "$epic_id"
  else
    echo "Active epic: (none)"
  fi
  if [ -n "$story_id" ]; then
    active_story_line "$PRD_FILE" "$story_id"
  else
    echo "Active story: (all stories passed)"
  fi
  story_totals "$PRD_FILE"
  latest_story_commit_line
  next_epic_line "$epics_file"
  next_action_line "$PRD_FILE" "$epic_id" "$epics_file" "$loop_state"
  echo "Story status:"
  story_status_lines "$PRD_FILE"
}

main "$@"
