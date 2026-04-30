#!/bin/bash
# ralph-story.sh — Story management for the story-task architecture.
#
# Stories replace epics as the sprint-level planning unit.
# Each story is a task container with its own story.json.
#
# Usage:
#   ./ralph-story.sh <command> [args]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPRINTS_DIR="$SCRIPT_DIR/sprints"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
STORIES_FILE="${RALPH_STORIES_FILE:-}"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

fail() { echo "ERROR: $1" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_cmd jq

get_active_sprint() {
  [ -f "$ACTIVE_SPRINT_FILE" ] || return 1
  awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE"
}

resolve_stories_file() {
  if [ -n "$STORIES_FILE" ]; then
    [ -f "$STORIES_FILE" ] || fail "Stories file not found: $STORIES_FILE"
    return
  fi

  local active_sprint
  active_sprint="$(get_active_sprint)" || fail "No active sprint. Use ralph-sprint.sh use <sprint-name>."

  STORIES_FILE="$SPRINTS_DIR/$active_sprint/stories.json"
  [ -f "$STORIES_FILE" ] || fail "No stories.json for sprint '$active_sprint'. Run ralph-sprint-migrate.sh or ralph-roadmap.sh first."
}

usage() {
  cat <<'EOF'
Usage: ./ralph-story.sh <command> [args]

Commands:
  list                       List all stories in the active sprint
  show <ID>                  Show full story.json for a story
  next                       Show the next eligible story (no blockers, lowest priority)
  next-id                    Print only the next eligible story ID
  use <ID>                   Set a story as the active story
  start-next                 Set next eligible story as active
  tasks <ID>                 List tasks in a story with their status
  set-status <ID> <STATUS>   Set story status (planned|ready|active|done|abandoned|blocked)
  abandon <ID> [REASON]      Mark story abandoned
  health [ID]                Validate story tasks: dead deps, duplicate checks, missing fields
  add [options]              Add a story non-interactively

Eligibility for "next":
  - status is ready or planned
  - all depends_on stories are done
  - lowest priority wins, then ID

Add options:
  --id S-XXX                 Explicit story ID (default: next sequential)
  --title TEXT               Story title (required)
  --priority N               Priority (default: next available)
  --effort N                 Effort: 1, 2, 3, or 5 (default: 3)
  --status STATUS            planned|ready (default: planned)
  --depends-on IDS           Comma-separated dependency IDs
  --prompt-context TEXT      Planning context for story generation
  --goal TEXT                Story goal description
EOF
}

# ---------------------------------------------------------------------------
# Resolve story file path (absolute)
# ---------------------------------------------------------------------------

resolve_story_path() {
  local story_id="$1"
  local raw_path
  raw_path="$(jq -r --arg id "$story_id" '.stories[] | select(.id == $id) | .story_path // empty' "$STORIES_FILE")"
  [ -n "$raw_path" ] || fail "Story $story_id not found in $STORIES_FILE"

  if [[ "$raw_path" != /* ]]; then
    echo "$WORKSPACE_ROOT/$raw_path"
  else
    echo "$raw_path"
  fi
}

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------

cmd_list() {
  resolve_stories_file

  local sprint
  sprint="$(jq -r '.sprint' "$STORIES_FILE")"
  local active_id
  active_id="$(jq -r '.activeStoryId // "none"' "$STORIES_FILE")"

  echo "Sprint: $sprint   active=$active_id"
  echo ""
  printf "%-10s %-6s %-6s %-12s %s\n" "ID" "PRI" "EFF" "STATUS" "TITLE"
  printf "%-10s %-6s %-6s %-12s %s\n" "----------" "------" "------" "------------" "-----"

  jq -r '
    .stories | sort_by(.priority) | .[] |
    [.id, (.priority|tostring), (.effort|tostring), .status, .title] | @tsv
  ' "$STORIES_FILE" | while IFS=$'\t' read -r sid pri eff status title; do
    marker="  "
    [ "$sid" = "$active_id" ] && marker="->"
    printf "%s %-8s %-6s %-6s %-12s %s\n" "$marker" "$sid" "$pri" "$eff" "$status" "$title"
  done
}

# ---------------------------------------------------------------------------
# show
# ---------------------------------------------------------------------------

cmd_show() {
  local story_id="${1:-}"
  [ -n "$story_id" ] || fail "Usage: ralph-story.sh show <ID>"
  resolve_stories_file

  local story_path
  story_path="$(resolve_story_path "$story_id")"
  [ -f "$story_path" ] || fail "story.json not found at: $story_path"
  jq '.' "$story_path"
}

# ---------------------------------------------------------------------------
# next / next-id
# ---------------------------------------------------------------------------

cmd_next_id() {
  resolve_stories_file

  jq -r '
    .stories
    | map(select(.status == "ready" or .status == "planned"))
    | sort_by([.priority, .id])
    | .[]
    | .id
  ' "$STORIES_FILE" | while IFS= read -r sid; do
    # Check dependencies
    local deps_ok=true
    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      dep_status="$(jq -r --arg d "$dep" '.stories[] | select(.id == $d) | .status' "$STORIES_FILE")"
      if [ "$dep_status" != "done" ]; then
        deps_ok=false
        break
      fi
    done < <(jq -r --arg id "$sid" '.stories[] | select(.id == $id) | .depends_on[]?' "$STORIES_FILE")
    if [ "$deps_ok" = "true" ]; then
      echo "$sid"
      return 0
    fi
  done
}

cmd_next() {
  resolve_stories_file
  local next_id
  next_id="$(cmd_next_id)"
  [ -n "$next_id" ] || { echo "No eligible story found."; return 0; }

  jq --arg id "$next_id" '.stories[] | select(.id == $id)' "$STORIES_FILE"
}

# ---------------------------------------------------------------------------
# use
# ---------------------------------------------------------------------------

cmd_use() {
  local story_id="${1:-}"
  [ -n "$story_id" ] || fail "Usage: ralph-story.sh use <ID>"
  resolve_stories_file

  local exists
  exists="$(jq -r --arg id "$story_id" '.stories[] | select(.id == $id) | .id' "$STORIES_FILE")"
  [ -n "$exists" ] || fail "Story $story_id not found."

  local tmp
  tmp="$(mktemp)"
  jq --arg id "$story_id" '.activeStoryId = $id' "$STORIES_FILE" > "$tmp"
  mv "$tmp" "$STORIES_FILE"

  echo "Active story set to: $story_id"
}

# ---------------------------------------------------------------------------
# start-next
# ---------------------------------------------------------------------------

cmd_start_next() {
  resolve_stories_file
  local next_id
  next_id="$(cmd_next_id)"
  [ -n "$next_id" ] || fail "No eligible story to start."

  local tmp
  tmp="$(mktemp)"
  jq --arg id "$next_id" '
    (.stories[] | select(.id == $id) | .status) = "active" |
    .activeStoryId = $id
  ' "$STORIES_FILE" > "$tmp"
  mv "$tmp" "$STORIES_FILE"

  echo "Started story: $next_id"
}

# ---------------------------------------------------------------------------
# tasks
# ---------------------------------------------------------------------------

cmd_tasks() {
  local story_id="${1:-}"
  [ -n "$story_id" ] || fail "Usage: ralph-story.sh tasks <ID>"
  resolve_stories_file

  local story_path
  story_path="$(resolve_story_path "$story_id")"
  [ -f "$story_path" ] || fail "story.json not found at: $story_path"

  echo "Tasks for story $story_id:"
  echo ""
  printf "%-8s %-8s %s\n" "ID" "STATUS" "TITLE"
  printf "%-8s %-8s %s\n" "--------" "--------" "-----"
  jq -r '.tasks[] | [.id, .status, .title] | @tsv' "$story_path" \
    | while IFS=$'\t' read -r tid tstatus ttitle; do
      printf "%-8s %-8s %s\n" "$tid" "$tstatus" "$ttitle"
    done
}

# ---------------------------------------------------------------------------
# set-status
# ---------------------------------------------------------------------------

cmd_set_status() {
  local story_id="${1:-}"
  local new_status="${2:-}"
  [ -n "$story_id" ] && [ -n "$new_status" ] || fail "Usage: ralph-story.sh set-status <ID> <STATUS>"
  resolve_stories_file

  local valid_statuses="planned ready active done abandoned blocked"
  echo "$valid_statuses" | grep -qw "$new_status" || fail "Invalid status '$new_status'. Valid: $valid_statuses"

  local tmp
  tmp="$(mktemp)"
  jq --arg id "$story_id" --arg s "$new_status" \
    '(.stories[] | select(.id == $id) | .status) = $s' \
    "$STORIES_FILE" > "$tmp"
  mv "$tmp" "$STORIES_FILE"

  echo "Story $story_id status set to: $new_status"
}

# ---------------------------------------------------------------------------
# abandon
# ---------------------------------------------------------------------------

cmd_abandon() {
  local story_id="${1:-}"
  local reason="${2:-}"
  [ -n "$story_id" ] || fail "Usage: ralph-story.sh abandon <ID> [REASON]"
  resolve_stories_file

  local tmp
  tmp="$(mktemp)"
  jq --arg id "$story_id" --arg r "$reason" \
    '(.stories[] | select(.id == $id)) |= . + {"status": "abandoned", "abandonReason": $r}' \
    "$STORIES_FILE" > "$tmp"
  mv "$tmp" "$STORIES_FILE"

  echo "Story $story_id marked abandoned."
}

# ---------------------------------------------------------------------------
# health
# ---------------------------------------------------------------------------

_health_story() {
  local story_id="$1"
  local story_path
  story_path="$(resolve_story_path "$story_id")"
  local story_status
  story_status="$(jq -r --arg id "$story_id" '.stories[] | select(.id == $id) | .status' "$STORIES_FILE")"
  local issues=0

  echo "[$story_id] $story_status"

  if [ ! -f "$story_path" ]; then
    echo "  [MISSING] story.json not found: $story_path"
    return 1
  fi

  local task_count
  task_count="$(jq '.tasks | length' "$story_path")"
  if [ "$task_count" -eq 0 ]; then
    echo "  [WARN] No tasks defined"
    issues=$((issues + 1))
  fi

  # Per-task checks: missing checks, empty context, dead depends_on
  while IFS= read -r tid; do
    local check_count
    check_count="$(jq -r --arg id "$tid" '.tasks[] | select(.id == $id) | .checks | length' "$story_path")"
    if [ "$check_count" -eq 0 ]; then
      echo "  [WARN] $tid: no acceptance checks"
      issues=$((issues + 1))
    fi

    local ctx
    ctx="$(jq -r --arg id "$tid" '.tasks[] | select(.id == $id) | .context // ""' "$story_path")"
    if [ -z "$ctx" ] || [ "$ctx" = "null" ]; then
      echo "  [WARN] $tid: empty context"
      issues=$((issues + 1))
    fi

    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      local dep_exists
      dep_exists="$(jq -r --arg d "$dep" '.tasks[] | select(.id == $d) | .id' "$story_path")"
      if [ -z "$dep_exists" ]; then
        echo "  [DEAD] $tid: depends_on '$dep' not found in story"
        issues=$((issues + 1))
      fi
    done < <(jq -r --arg id "$tid" '.tasks[] | select(.id == $id) | .depends_on[]?' "$story_path")
  done < <(jq -r '.tasks[].id' "$story_path")

  # Duplicate checks within the same task's checks array
  while IFS= read -r tid; do
    local self_dups
    self_dups="$(jq -r --arg id "$tid" '
      (.tasks[] | select(.id == $id) | .checks // []) |
      group_by(.) | map(select(length > 1) | .[0]) | .[]
    ' "$story_path" 2>/dev/null || true)"
    if [ -n "$self_dups" ]; then
      while IFS= read -r dup; do
        [ -z "$dup" ] && continue
        echo "  [DUP]  $tid: check listed more than once: $dup"
        issues=$((issues + 1))
      done <<< "$self_dups"
    fi
  done < <(jq -r '.tasks[].id' "$story_path")

  # Tasks with identical check sets (likely redundant)
  local dup_task_sets
  dup_task_sets="$(jq -r '
    .tasks |
    map({id: .id, checks: (.checks // [] | sort)}) |
    group_by(.checks) |
    map(select(length > 1) | map(.id) | join(", ")) |
    .[]
  ' "$story_path" 2>/dev/null || true)"
  if [ -n "$dup_task_sets" ]; then
    while IFS= read -r set; do
      [ -z "$set" ] && continue
      echo "  [DUP]  Tasks share identical check sets: $set"
      issues=$((issues + 1))
    done <<< "$dup_task_sets"
  fi

  # Self-referencing depends_on
  while IFS= read -r tid; do
    local self_dep
    self_dep="$(jq -r --arg id "$tid" '.tasks[] | select(.id == $id) | .depends_on[]? | select(. == $id)' "$story_path" 2>/dev/null || true)"
    if [ -n "$self_dep" ]; then
      echo "  [CYCLE] $tid: depends on itself"
      issues=$((issues + 1))
    fi
  done < <(jq -r '.tasks[].id' "$story_path")

  if [ "$issues" -eq 0 ]; then
    echo "  OK"
    return 0
  fi
  return 1
}

cmd_health() {
  resolve_stories_file

  local story_id="${1:-}"

  if [ -n "$story_id" ]; then
    _health_story "$story_id"
    return $?
  fi

  local any_issues=0
  while IFS= read -r sid; do
    _health_story "$sid" || any_issues=1
  done < <(jq -r '.stories[].id' "$STORIES_FILE")

  echo ""
  if [ "$any_issues" -eq 0 ]; then
    echo "All stories healthy."
  else
    echo "Issues found. Review warnings above."
    return 1
  fi
}

# ---------------------------------------------------------------------------
# add
# ---------------------------------------------------------------------------

cmd_add() {
  resolve_stories_file

  local new_title=""
  local new_id=""
  local new_priority=""
  local new_effort=3
  local new_status="planned"
  local new_depends=""
  local new_goal=""
  local new_prompt_context=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)             new_id="${2:-}"; shift 2 ;;
      --title)          new_title="${2:-}"; shift 2 ;;
      --priority)       new_priority="${2:-}"; shift 2 ;;
      --effort)         new_effort="${2:-3}"; shift 2 ;;
      --status)         new_status="${2:-planned}"; shift 2 ;;
      --depends-on)     new_depends="${2:-}"; shift 2 ;;
      --goal)           new_goal="${2:-}"; shift 2 ;;
      --prompt-context) new_prompt_context="${2:-}"; shift 2 ;;
      *) fail "Unknown add option: $1" ;;
    esac
  done

  [ -n "$new_title" ] || fail "--title is required"

  # Auto-assign ID
  if [ -z "$new_id" ]; then
    local max_n=0
    while IFS= read -r existing_id; do
      n="${existing_id#S-}"
      n="${n#0}"
      [ "$n" -gt "$max_n" ] 2>/dev/null && max_n="$n"
    done < <(jq -r '.stories[].id' "$STORIES_FILE")
    new_id="$(printf 'S-%03d' $((max_n + 1)))"
  fi

  # Auto-assign priority
  if [ -z "$new_priority" ]; then
    new_priority="$(jq '[.stories[].priority] | max + 1' "$STORIES_FILE")"
  fi

  # Build depends_on array
  local deps_json="[]"
  if [ -n "$new_depends" ]; then
    deps_json="$(echo "$new_depends" | tr ',' '\n' | jq -R . | jq -s .)"
  fi

  # Determine active sprint for story_path
  local active_sprint
  active_sprint="$(get_active_sprint)" || fail "No active sprint."
  local story_path="scripts/ralph/sprints/$active_sprint/stories/$new_id/story.json"

  local tmp
  tmp="$(mktemp)"
  jq \
    --arg id "$new_id" \
    --arg title "$new_title" \
    --argjson priority "$new_priority" \
    --argjson effort "$new_effort" \
    --arg status "$new_status" \
    --argjson depends "$deps_json" \
    --arg goal "$new_goal" \
    --arg ctx "$new_prompt_context" \
    --arg path "$story_path" \
    '.stories += [{
      "id": $id,
      "title": $title,
      "priority": $priority,
      "effort": $effort,
      "planningSource": "local",
      "status": $status,
      "depends_on": $depends,
      "story_path": $path,
      "goal": $goal,
      "promptContext": $ctx
    }]' \
    "$STORIES_FILE" > "$tmp"
  mv "$tmp" "$STORIES_FILE"

  echo "Added story: $new_id — $new_title"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

CMD="${1:-}"
shift || true

case "$CMD" in
  list)         cmd_list ;;
  show)         cmd_show "$@" ;;
  next)         cmd_next ;;
  next-id)      cmd_next_id ;;
  use)          cmd_use "$@" ;;
  start-next)   cmd_start_next ;;
  tasks)        cmd_tasks "$@" ;;
  set-status)   cmd_set_status "$@" ;;
  abandon)      cmd_abandon "$@" ;;
  health)       cmd_health "$@" ;;
  add)          cmd_add "$@" ;;
  -h|--help|"") usage; exit 0 ;;
  *) fail "Unknown command: $CMD. Use --help for usage." ;;
esac
