#!/bin/bash
# ralph-task.sh — Task executor for the story-task architecture.
#
# Runs each task in a story as an independent Codex session with minimal
# focused context. Validates binary acceptance checks without AI involvement.
# Enforces dependency ordering between tasks.
#
# Usage:
#   ./ralph-task.sh [--story PATH] [--task-id ID] [--max-retries N] [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CODEX_BIN="${CODEX_BIN:-codex}"
LOCK_DIR="$SCRIPT_DIR/.workflow-lock"

STORY_FILE=""
TARGET_TASK_ID=""
MAX_RETRIES=2
DRY_RUN=0
QUIET=0
SKIP_FALLOW=0

usage() {
  cat <<'EOF'
Usage: ./ralph-task.sh [options]

Run one or all tasks in a story. Each task gets a fresh Codex session.
Binary acceptance checks are validated by shell — no AI involvement.

Options:
  --story PATH        Path to story.json (default: active story from sprint)
  --task-id ID        Run only this task (e.g. T-02)
  --max-retries N     Retry count per task on check failure (default: 2)
  --dry-run           Print plan without executing Codex sessions
  --quiet             Suppress verbose output
  --skip-fallow       Skip the fallow code-quality gate (bypass for debugging)
  -h, --help          Show help

Environment:
  CODEX_BIN           Codex binary path (default: codex)
  RALPH_CODEX_PROFILE Profile flag passed to codex exec
EOF
}

fail() { echo "ERROR: $1" >&2; exit 1; }
log()  { [ "$QUIET" -eq 0 ] && echo "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --story)       STORY_FILE="${2:-}"; shift 2 ;;
    --task-id)     TARGET_TASK_ID="${2:-}"; shift 2 ;;
    --max-retries) MAX_RETRIES="${2:-2}"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --quiet)       QUIET=1; shift ;;
    --skip-fallow) SKIP_FALLOW=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_cmd jq
require_cmd git

# ---------------------------------------------------------------------------
# Resolve story file
# ---------------------------------------------------------------------------

resolve_story_file() {
  if [ -n "$STORY_FILE" ]; then
    [ -f "$STORY_FILE" ] || fail "Story file not found: $STORY_FILE"
    return
  fi

  local active_sprint_file="$SCRIPT_DIR/.active-sprint"
  [ -f "$active_sprint_file" ] || fail "No --story given and no .active-sprint found."
  local sprint
  sprint="$(cat "$active_sprint_file")"

  local stories_file="$SCRIPT_DIR/sprints/$sprint/stories.json"
  [ -f "$stories_file" ] || fail "No stories.json for sprint $sprint: $stories_file"

  local active_id
  active_id="$(jq -r '.activeStoryId // empty' "$stories_file")"
  [ -n "$active_id" ] || fail "No activeStoryId set in $stories_file. Run ralph-story.sh use <id> first."

  local story_path
  story_path="$(jq -r --arg id "$active_id" '.stories[] | select(.id == $id) | .story_path // empty' "$stories_file")"
  [ -n "$story_path" ] || fail "Story $active_id not found in $stories_file"

  if [[ "$story_path" != /* ]]; then
    story_path="$WORKSPACE_ROOT/$story_path"
  fi
  [ -f "$story_path" ] || fail "Story file not found: $story_path"
  STORY_FILE="$story_path"
}

resolve_story_file

STORY_DIR="$(dirname "$STORY_FILE")"

# ---------------------------------------------------------------------------
# Dependency resolution
# ---------------------------------------------------------------------------

task_status() {
  local task_id="$1"
  jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .status // "pending"' "$STORY_FILE"
}

task_passes() {
  local task_id="$1"
  jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .passes // false' "$STORY_FILE"
}

deps_met() {
  local task_id="$1"
  local deps
  deps="$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .depends_on[]?' "$STORY_FILE")"
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    local dep_passes
    dep_passes="$(task_passes "$dep")"
    if [ "$dep_passes" != "true" ]; then
      return 1
    fi
  done <<< "$deps"
  return 0
}

# ---------------------------------------------------------------------------
# Acceptance check runner
# ---------------------------------------------------------------------------

run_checks() {
  local task_id="$1"
  local checks_json
  checks_json="$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .checks[]?' "$STORY_FILE")"

  local all_pass=0
  local check_num=0
  while IFS= read -r check; do
    [ -z "$check" ] && continue
    check_num=$((check_num + 1))
    log "    check[$check_num]: $check"
    if (cd "$WORKSPACE_ROOT" && eval "$check") >/dev/null 2>&1; then
      log "    PASS"
    else
      log "    FAIL"
      all_pass=1
    fi
  done <<< "$checks_json"

  return $all_pass
}

# ---------------------------------------------------------------------------
# Story file mutation helpers (POSIX-safe, uses temp file)
# ---------------------------------------------------------------------------

set_task_field() {
  local task_id="$1"
  local field="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$task_id" --arg field "$field" --argjson val "$value" \
    '(.tasks[] | select(.id == $id) | .[$field]) = $val' \
    "$STORY_FILE" > "$tmp"
  mv "$tmp" "$STORY_FILE"
}

mark_task_done() {
  local task_id="$1"
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$task_id" \
    '(.tasks[] | select(.id == $id)) |= . + {"status": "done", "passes": true}' \
    "$STORY_FILE" > "$tmp"
  mv "$tmp" "$STORY_FILE"
}

mark_task_failed() {
  local task_id="$1"
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$task_id" \
    '(.tasks[] | select(.id == $id)) |= . + {"status": "failed", "passes": false}' \
    "$STORY_FILE" > "$tmp"
  mv "$tmp" "$STORY_FILE"
}

mark_story_done() {
  local tmp
  tmp="$(mktemp)"
  jq '. + {"status": "done", "passes": true}' "$STORY_FILE" > "$tmp"
  mv "$tmp" "$STORY_FILE"
}

set_story_field() {
  local field="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg field "$field" --argjson val "$value" \
    '.[$field] = $val' \
    "$STORY_FILE" > "$tmp"
  mv "$tmp" "$STORY_FILE"
}

# ---------------------------------------------------------------------------
# Codex session builder
# ---------------------------------------------------------------------------

build_task_prompt() {
  local task_id="$1"
  local title context scope_list acceptance

  title="$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .title' "$STORY_FILE")"
  context="$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .context' "$STORY_FILE")"
  scope_list="$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .scope[]?' "$STORY_FILE" | paste -sd ', ' -)"
  acceptance="$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .acceptance' "$STORY_FILE")"

  local story_title story_description story_spec_scope preserved_invariants
  story_title="$(jq -r '.title' "$STORY_FILE")"
  story_description="$(jq -r '.description // ""' "$STORY_FILE")"
  story_spec_scope="$(jq -r '.spec.scope // ""' "$STORY_FILE")"
  preserved_invariants="$(jq -r '.spec.preserved_invariants[]?' "$STORY_FILE" | awk '{print "- "$0}')"

  # ---- Task dependency notes (only fetched if depends_on is non-empty) ----
  local task_dep_block=""
  local _dep_id _dep_title _dep_note
  while IFS= read -r _dep_id; do
    [ -z "$_dep_id" ] && continue
    _dep_title="$(jq -r --arg id "$_dep_id" '.tasks[] | select(.id == $id) | .title // ""' "$STORY_FILE")"
    _dep_note="$(jq -r --arg id "$_dep_id" '.tasks[] | select(.id == $id) | .done_note // ""' "$STORY_FILE")"
    [ -n "$_dep_note" ] || continue
    task_dep_block="${task_dep_block}- ${_dep_id} (${_dep_title}):
$(printf '%s' "$_dep_note" | sed 's/^/  /')
"
  done < <(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .depends_on[]?' "$STORY_FILE" 2>/dev/null)

  # ---- Story dependency notes (only fetched if story depends_on is non-empty) ----
  local story_dep_block=""
  local _sprint _stories_file _dep_sid _dep_spath _dep_stitle _dep_snote
  _sprint=""
  [ -f "$SCRIPT_DIR/.active-sprint" ] && _sprint="$(awk 'NF {print; exit}' "$SCRIPT_DIR/.active-sprint")"
  _stories_file="$SCRIPT_DIR/sprints/${_sprint}/stories.json"
  while IFS= read -r _dep_sid; do
    [ -z "$_dep_sid" ] && continue
    [ -n "$_sprint" ] && [ -f "$_stories_file" ] || continue
    _dep_spath="$(jq -r --arg id "$_dep_sid" '.stories[] | select(.id == $id) | .story_path // ""' "$_stories_file" 2>/dev/null)"
    [ -n "$_dep_spath" ] || continue
    [[ "$_dep_spath" != /* ]] && _dep_spath="$WORKSPACE_ROOT/$_dep_spath"
    [ -f "$_dep_spath" ] || continue
    _dep_stitle="$(jq -r '.title // ""' "$_dep_spath" 2>/dev/null)"
    _dep_snote="$(jq -r '.done_note // ""' "$_dep_spath" 2>/dev/null)"
    [ -n "$_dep_snote" ] || continue
    story_dep_block="${story_dep_block}- ${_dep_sid} (${_dep_stitle}):
$(printf '%s' "$_dep_snote" | sed 's/^/  /')
"
  done < <(jq -r '.depends_on[]?' "$STORY_FILE" 2>/dev/null)

  # ---- Assemble optional dependency sections ----
  local dep_sections=""
  if [ -n "$story_dep_block" ]; then
    dep_sections="${dep_sections}**Prior story results (dependencies):**
${story_dep_block}
"
  fi
  if [ -n "$task_dep_block" ]; then
    dep_sections="${dep_sections}**Prior task results (dependencies):**
${task_dep_block}
"
  fi

  cat <<PROMPT
## Task: $title

**Story:** $story_title
**Goal:** $story_description
**Story scope:** $story_spec_scope

${dep_sections}**Task context:**
$context

**File scope:** $scope_list

**Acceptance:** $acceptance

**Preserved invariants (do not break):**
$preserved_invariants

Complete this task. Stay within the file scope listed. Commit the change when done.
PROMPT
}

run_codex_session() {
  local task_id="$1"
  local prompt
  prompt="$(build_task_prompt "$task_id")"

  local log_file="$STORY_DIR/.task-log-$task_id.txt"
  local profile_flag=""
  if [ -n "${RALPH_CODEX_PROFILE:-}" ]; then
    profile_flag="--profile $RALPH_CODEX_PROFILE"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[DRY RUN] Would run codex session for $task_id"
    log "--- prompt ---"
    log "$prompt"
    log "--------------"
    return 0
  fi

  log "  Running Codex session for $task_id..."
  # shellcheck disable=SC2086
  "$CODEX_BIN" exec $profile_flag --quiet "$prompt" 2>&1 | tee "$log_file"
}

# ---------------------------------------------------------------------------
# Workflow lock
# ---------------------------------------------------------------------------

acquire_lock() {
  if [ "${RALPH_LOCK_HELD:-0}" = "1" ]; then return 0; fi
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    RALPH_LOCK_HELD=1
    export RALPH_LOCK_HELD
    trap 'rmdir "$LOCK_DIR" 2>/dev/null; exit' INT TERM EXIT
    return 0
  fi
  fail "Another Ralph workflow is running (lock: $LOCK_DIR). Use ralph-cleanup.sh --force to clear stale locks."
}

acquire_lock

STORY_START_HEAD="$(git -C "$WORKSPACE_ROOT" rev-parse HEAD 2>/dev/null || echo "")"

# ---------------------------------------------------------------------------
# Main execution loop
# ---------------------------------------------------------------------------

STORY_TITLE="$(jq -r '.title' "$STORY_FILE")"
STORY_ID="$(jq -r '.storyId' "$STORY_FILE")"
log ""
log "=== ralph-task: $STORY_ID — $STORY_TITLE ==="
log "Story file: $STORY_FILE"
log ""

# Collect task IDs to run
TASK_IDS=()
if [ -n "$TARGET_TASK_ID" ]; then
  # Validate the task exists
  local_exists="$(jq -r --arg id "$TARGET_TASK_ID" '.tasks[] | select(.id == $id) | .id' "$STORY_FILE")"
  [ -n "$local_exists" ] || fail "Task $TARGET_TASK_ID not found in story."
  TASK_IDS=("$TARGET_TASK_ID")
else
  while IFS= read -r tid; do
    TASK_IDS+=("$tid")
  done < <(jq -r '.tasks[].id' "$STORY_FILE")
fi

STORY_FAILED=0

for task_id in "${TASK_IDS[@]}"; do
  task_title="$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .title' "$STORY_FILE")"
  current_status="$(task_status "$task_id")"
  current_passes="$(task_passes "$task_id")"

  log "--- Task $task_id: $task_title ---"

  # Skip already-done tasks
  if [ "$current_passes" = "true" ]; then
    log "  SKIP — already passes"
    continue
  fi

  # Check dependencies
  if ! deps_met "$task_id"; then
    log "  BLOCKED — dependencies not yet satisfied"
    STORY_FAILED=1
    continue
  fi

  set_task_field "$task_id" "status" '"running"'
  task_start_head="$(git -C "$WORKSPACE_ROOT" rev-parse HEAD 2>/dev/null || echo "")"

  attempt=0
  task_passed=0
  while [ $attempt -le "$MAX_RETRIES" ]; do
    attempt=$((attempt + 1))
    log "  Attempt $attempt/$((MAX_RETRIES + 1))..."

    run_codex_session "$task_id"

    log "  Validating acceptance checks..."
    if run_checks "$task_id"; then
      log "  PASS — all checks green"
      mark_task_done "$task_id"
      _task_end_head="$(git -C "$WORKSPACE_ROOT" rev-parse HEAD 2>/dev/null || echo "")"
      _task_acceptance="$(jq -r --arg id "$task_id" '.tasks[] | select(.id == $id) | .acceptance // ""' "$STORY_FILE")"
      if [ -n "$task_start_head" ] && [ "$task_start_head" != "$_task_end_head" ]; then
        _task_diff="$(git -C "$WORKSPACE_ROOT" diff --stat "${task_start_head}..${_task_end_head}" 2>/dev/null | tail -1 | sed 's/^ *//')"
      else
        _task_diff="no new commits"
      fi
      _done_note="Acceptance met: ${_task_acceptance}
Changed: ${_task_diff}"
      set_task_field "$task_id" "done_note" "$(printf '%s' "$_done_note" | jq -Rs .)"
      task_passed=1
      break
    else
      log "  Checks failed (attempt $attempt)"
      if [ $attempt -le "$MAX_RETRIES" ]; then
        log "  Retrying..."
      fi
    fi
  done

  if [ $task_passed -eq 0 ]; then
    log "  FAILED after $attempt attempts — marking task failed"
    mark_task_failed "$task_id"
    STORY_FAILED=1
  fi

  log ""
done

# Check if all tasks pass and mark story done
if [ $STORY_FAILED -eq 0 ]; then
  all_pass=true
  while IFS= read -r passes; do
    if [ "$passes" != "true" ]; then
      all_pass=false
      break
    fi
  done < <(jq -r '.tasks[].passes' "$STORY_FILE")

  if [ "$all_pass" = "true" ]; then
    # Run fallow code-quality gate (skippable for debugging)
    if [ "$SKIP_FALLOW" -eq 0 ] && [ -f "$SCRIPT_DIR/ralph-fallow.sh" ]; then
      log ""
      log "--- Fallow: code-quality gate ---"
      local_fallow_args=(--story "$STORY_FILE")
      [ "$DRY_RUN" -eq 1 ] && local_fallow_args+=(--dry-run)
      [ "$QUIET" -eq 1 ]   && local_fallow_args+=(--quiet)
      if ! "$SCRIPT_DIR/ralph-fallow.sh" "${local_fallow_args[@]}"; then
        log "=== Story $STORY_ID: fallow gate failed — manual correction required ==="
        exit 1
      fi
    fi
    _story_end_head="$(git -C "$WORKSPACE_ROOT" rev-parse HEAD 2>/dev/null || echo "")"
    if [ -n "$STORY_START_HEAD" ] && [ "$STORY_START_HEAD" != "$_story_end_head" ]; then
      _story_total_diff="$(git -C "$WORKSPACE_ROOT" diff --stat "${STORY_START_HEAD}..${_story_end_head}" 2>/dev/null | tail -1 | sed 's/^ *//')"
    else
      _story_total_diff="no new commits"
    fi
    _story_task_notes="$(jq -r '.tasks[] | select(.passes == true) | "  \(.id) (\(.title)): Acceptance met: \(.acceptance)"' "$STORY_FILE")"
    _story_done_note="${_story_task_notes}
Total changed: ${_story_total_diff}"
    set_story_field "done_note" "$(printf '%s' "$_story_done_note" | jq -Rs .)"

    mark_story_done

    # Sync stories.json: mark story done and clear activeStoryId
    local active_sprint_file="$SCRIPT_DIR/.active-sprint"
    if [ -f "$active_sprint_file" ]; then
      local sprint stories_file stmp
      sprint="$(awk 'NF {print; exit}' "$active_sprint_file")"
      stories_file="$SCRIPT_DIR/sprints/$sprint/stories.json"
      if [ -f "$stories_file" ]; then
        stmp="$(mktemp)"
        jq --arg id "$STORY_ID" '
          .stories = [.stories[] | if .id == $id then .status = "done" | .passes = true else . end]
          | .activeStoryId = null
        ' "$stories_file" > "$stmp"
        mv "$stmp" "$stories_file"
        log "Updated stories.json: $STORY_ID → done"
      fi
    fi

    log "=== Story $STORY_ID COMPLETE ==="
    exit 0
  fi
fi

log "=== Story $STORY_ID: some tasks incomplete or blocked ==="
exit 1
