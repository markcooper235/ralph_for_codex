#!/bin/bash
# ralph-sprint-migrate.sh — Convert a sprint from epic/PRD format to story-task format.
#
# Migration mapping:
#   epics.json epic          → stories.json entry + story.json file
#   epic.id (EPIC-XXX)       → story.storyId (S-XXX)
#   epic.title               → story.title
#   epic.goal                → story.description + spec.scope
#   epic.dependsOn           → story.depends_on (IDs remapped EPIC-XXX → S-XXX)
#   epic.status              → story.status
#   epic.effort              → story.effort
#   epic.planningSource      → story.planningSource
#   PRD userStory.id         → task.id (US-XXX → T-XX)
#   PRD userStory.description + acceptanceCriteria → task.context + task.acceptance
#   PRD userStory.scopePaths → task.scope
#   acceptanceCriteria keywords → task.checks (inferred: typecheck/tests/lint)
#   PRD branchName           → story.branchName
#
# Usage:
#   ./ralph-sprint-migrate.sh [--sprint SPRINT] [--dry-run] [--force]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPRINTS_DIR="$SCRIPT_DIR/sprints"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

TARGET_SPRINT=""
DRY_RUN=0
FORCE=0

usage() {
  cat <<'EOF'
Usage: ./ralph-sprint-migrate.sh [options]

Convert a sprint from epics.json / PRD format to stories.json / story.json format.

Options:
  --sprint NAME    Sprint to migrate (default: active sprint)
  --dry-run        Print migration plan without writing files
  --force          Overwrite existing stories.json and story.json files
  -h, --help       Show help

The migration is non-destructive by default:
  - epics.json is NOT removed; stories.json is written alongside it
  - Existing story.json files are skipped unless --force is used
  - PRD markdown is preserved; story.json references it under spec.prdPath

After migration, verify with:
  ./ralph-story.sh list
  ./ralph-story.sh tasks S-001
EOF
}

fail() { echo "ERROR: $1" >&2; exit 1; }
log()  { echo "$1"; }
dry()  { [ "$DRY_RUN" -eq 0 ] && return 0 || return 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sprint)   TARGET_SPRINT="${2:-}"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --force)    FORCE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_cmd jq

# Resolve sprint
if [ -z "$TARGET_SPRINT" ]; then
  [ -f "$ACTIVE_SPRINT_FILE" ] || fail "No --sprint given and no .active-sprint file found."
  TARGET_SPRINT="$(awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE")"
fi

SPRINT_DIR="$SPRINTS_DIR/$TARGET_SPRINT"
EPICS_FILE="$SPRINT_DIR/epics.json"
STORIES_FILE="$SPRINT_DIR/stories.json"
STORIES_SUBDIR="$SPRINT_DIR/stories"
TASKS_PRD_DIR="$SCRIPT_DIR/tasks"

[ -d "$SPRINT_DIR" ] || fail "Sprint directory not found: $SPRINT_DIR"
[ -f "$EPICS_FILE" ] || fail "epics.json not found: $EPICS_FILE"

if [ -f "$STORIES_FILE" ] && [ "$FORCE" -eq 0 ]; then
  fail "stories.json already exists at $STORIES_FILE. Use --force to overwrite."
fi

log "=== ralph-sprint-migrate: $TARGET_SPRINT ==="
log "Source: $EPICS_FILE"
log "Target: $STORIES_FILE"
[ "$DRY_RUN" -eq 1 ] && log "[DRY RUN — no files will be written]"
log ""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Remap EPIC-XXX → S-XXX
remap_id() {
  local raw="$1"
  # Already S-format
  echo "$raw" | grep -q '^S-[0-9]' && { echo "$raw"; return; }
  # EPIC-XXX → S-XXX
  local num
  num="$(echo "$raw" | sed 's/^EPIC-0*//')"
  printf 'S-%03d' "$num"
}

# Remap US-XXX → T-XX
remap_task_id() {
  local raw="$1"
  local num
  num="$(echo "$raw" | sed 's/^US-0*//')"
  printf 'T-%02d' "$num"
}

# Infer machine-executable checks from acceptance criteria text
infer_checks() {
  local criteria_json="$1"
  local checks="[]"

  if echo "$criteria_json" | grep -qi 'typecheck\|tsc\|type check\|type-check'; then
    checks="$(echo "$checks" | jq '. + ["npm run typecheck"]')"
  fi
  if echo "$criteria_json" | grep -qi '\btest\b\|jest\|vitest\|pytest\|go test'; then
    checks="$(echo "$checks" | jq '. + ["npm test"]')"
  fi
  if echo "$criteria_json" | grep -qi 'lint\|eslint'; then
    checks="$(echo "$checks" | jq '. + ["npm run lint"]')"
  fi
  if echo "$criteria_json" | grep -qi 'build\b'; then
    checks="$(echo "$checks" | jq '. + ["npm run build"]')"
  fi

  # Fallback: at minimum require typecheck if no checks inferred
  if [ "$checks" = "[]" ]; then
    checks='["npm run typecheck"]'
  fi

  echo "$checks"
}

# Find the PRD file for an epic from prdPaths or fallback search
find_prd_json_for_epic() {
  local epic_id="$1"
  local prd_paths_json="$2"

  # Try prdPaths first
  local prd_path
  prd_path="$(echo "$prd_paths_json" | jq -r 'first // empty')"
  if [ -n "$prd_path" ]; then
    # Convert .md path to attempt to find prd.json (not all epics have prd.json)
    echo "$prd_path"
    return
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# Load epics
# ---------------------------------------------------------------------------

EPIC_COUNT="$(jq '.epics | length' "$EPICS_FILE")"
SPRINT_PROJECT="$(jq -r '.project' "$EPICS_FILE")"
CAPACITY_TARGET="$(jq -r '.capacityTarget // 8' "$EPICS_FILE")"
CAPACITY_CEILING="$(jq -r '.capacityCeiling // 10' "$EPICS_FILE")"

log "Project: $SPRINT_PROJECT"
log "Epics to migrate: $EPIC_COUNT"
log ""

# ---------------------------------------------------------------------------
# Build stories.json entries and story.json files
# ---------------------------------------------------------------------------

STORIES_ENTRIES="[]"
MIGRATED=0
SKIPPED=0

for i in $(seq 0 $((EPIC_COUNT - 1))); do
  epic="$(jq ".epics[$i]" "$EPICS_FILE")"

  epic_id="$(echo "$epic" | jq -r '.id')"
  epic_title="$(echo "$epic" | jq -r '.title')"
  epic_goal="$(echo "$epic" | jq -r '.goal // ""')"
  epic_status="$(echo "$epic" | jq -r '.status')"
  epic_effort="$(echo "$epic" | jq -r '.effort // 3')"
  epic_priority="$(echo "$epic" | jq -r '.priority')"
  epic_planning_source="$(echo "$epic" | jq -r '.planningSource // "local"')"
  epic_prompt_context="$(echo "$epic" | jq -r '.promptContext // ""')"
  epic_depends_raw="$(echo "$epic" | jq -r '.dependsOn[]?' | tr '\n' ',')"
  epic_prd_paths="$(echo "$epic" | jq -r '.prdPaths // []')"

  story_id="$(remap_id "$epic_id")"
  story_path_rel="scripts/ralph/sprints/$TARGET_SPRINT/stories/$story_id/story.json"
  story_path_abs="$WORKSPACE_ROOT/$story_path_rel"

  log "  $epic_id → $story_id: $epic_title"

  # Remap dependencies
  deps_json="[]"
  if [ -n "$epic_depends_raw" ]; then
    while IFS= read -r dep_raw; do
      [ -z "$dep_raw" ] && continue
      dep_new="$(remap_id "$dep_raw")"
      deps_json="$(echo "$deps_json" | jq --arg d "$dep_new" '. + [$d]')"
    done < <(echo "$epic" | jq -r '.dependsOn[]?')
  fi

  # Build stories.json entry
  story_entry="$(jq -n \
    --arg id "$story_id" \
    --arg title "$epic_title" \
    --argjson priority "$epic_priority" \
    --argjson effort "$epic_effort" \
    --arg ps "$epic_planning_source" \
    --arg status "$epic_status" \
    --argjson depends "$deps_json" \
    --arg path "$story_path_rel" \
    --arg goal "$epic_goal" \
    --arg ctx "$epic_prompt_context" \
    '{
      "id": $id,
      "title": $title,
      "priority": $priority,
      "effort": $effort,
      "planningSource": $ps,
      "status": $status,
      "depends_on": $depends,
      "story_path": $path,
      "goal": $goal,
      "promptContext": $ctx
    }')"

  STORIES_ENTRIES="$(echo "$STORIES_ENTRIES" | jq --argjson entry "$story_entry" '. + [$entry]')"

  # Build story.json from PRD if available
  if [ -f "$story_path_abs" ] && [ "$FORCE" -eq 0 ]; then
    log "    SKIP story.json (exists, use --force to overwrite)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Find PRD markdown path
  prd_md_path="$(echo "$epic" | jq -r '.prdPaths[0] // empty')"

  TASKS_JSON="[]"
  STORY_BRANCH=""
  STORY_SCOPE=""
  STORY_OUT_OF_SCOPE="[]"
  STORY_FIRST_SLICE='{}'
  STORY_INVARIANTS="[]"
  STORY_SUPPORTING="[]"
  STORY_VERIFICATION="[]"
  PRD_MD_REF=""

  # Try to parse the PRD JSON (prd.json may have been archived; use prdPaths as reference)
  # We rely on the prd.json.example shape: project, branchName, userStories[]
  # Look for prd.json in task archive or current location
  prd_json_candidates=()
  if [ -n "$prd_md_path" ]; then
    PRD_MD_REF="$prd_md_path"
    # Infer prd.json sibling or sprint task directory
    prd_dir="$(dirname "$WORKSPACE_ROOT/$prd_md_path")"
    if [ -f "$prd_dir/prd.json" ]; then
      prd_json_candidates+=("$prd_dir/prd.json")
    fi
  fi
  # Also check current runtime prd.json if it matches this epic
  if [ -f "$SCRIPT_DIR/prd.json" ]; then
    prd_json_candidates+=("$SCRIPT_DIR/prd.json")
  fi

  for prd_json_path in "${prd_json_candidates[@]:-}"; do
    [ -f "$prd_json_path" ] || continue
    branch_check="$(jq -r '.branchName // empty' "$prd_json_path")"
    [ -n "$branch_check" ] || continue
    STORY_BRANCH="$branch_check"

    story_count="$(jq '.userStories | length' "$prd_json_path")"

    for j in $(seq 0 $((story_count - 1))); do
      us="$(jq ".userStories[$j]" "$prd_json_path")"
      us_id="$(echo "$us" | jq -r '.id')"
      us_title="$(echo "$us" | jq -r '.title')"
      us_desc="$(echo "$us" | jq -r '.description // ""')"
      us_scope="$(echo "$us" | jq -r '.scopePaths // []')"
      us_ac="$(echo "$us" | jq -r '.acceptanceCriteria // []')"
      us_passes="$(echo "$us" | jq -r '.passes // false')"
      us_notes="$(echo "$us" | jq -r '.notes // ""')"

      task_id="$(remap_task_id "$us_id")"

      # Build context from description + acceptance criteria
      ac_text="$(echo "$us_ac" | jq -r '.[]' | awk '{print "- "$0}')"
      task_context="$us_desc"
      [ -n "$ac_text" ] && task_context="$task_context

Acceptance:
$ac_text"

      # Build acceptance (human-readable summary from AC)
      ac_summary="$(echo "$us_ac" | jq -r 'join(". ")')"

      # Infer checks
      task_checks="$(infer_checks "$(echo "$us_ac" | jq -r '. | @json')")"

      # Task status from passes field
      task_status="pending"
      [ "$us_passes" = "true" ] && task_status="done"

      task_obj="$(jq -n \
        --arg id "$task_id" \
        --arg title "$us_title" \
        --arg context "$task_context" \
        --argjson scope "$us_scope" \
        --arg acceptance "$ac_summary" \
        --argjson checks "$task_checks" \
        --arg status "$task_status" \
        --argjson passes "$us_passes" \
        '{
          "id": $id,
          "title": $title,
          "context": $context,
          "scope": $scope,
          "acceptance": $acceptance,
          "checks": $checks,
          "depends_on": [],
          "status": $status,
          "passes": $passes
        }')"

      TASKS_JSON="$(echo "$TASKS_JSON" | jq --argjson t "$task_obj" '. + [$t]')"
    done
    STORY_SCOPE="$(jq -r '.description // ""' "$prd_json_path")"
    break
  done

  # Fall back to goal as scope if no PRD parsed
  [ -z "$STORY_SCOPE" ] && STORY_SCOPE="$epic_goal"
  [ -z "$STORY_BRANCH" ] && STORY_BRANCH="ralph/$TARGET_SPRINT/$(echo "$epic_title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')"

  story_json="$(jq -n \
    --arg version "1" \
    --arg project "$SPRINT_PROJECT" \
    --arg storyId "$story_id" \
    --arg title "$epic_title" \
    --arg description "$epic_goal" \
    --arg branchName "$STORY_BRANCH" \
    --arg sprint "$TARGET_SPRINT" \
    --argjson priority "$epic_priority" \
    --argjson depends "$deps_json" \
    --arg status "$epic_status" \
    --arg scope "$STORY_SCOPE" \
    --argjson outOfScope "$STORY_OUT_OF_SCOPE" \
    --argjson firstSlice "$STORY_FIRST_SLICE" \
    --argjson invariants "$STORY_INVARIANTS" \
    --argjson supporting "$STORY_SUPPORTING" \
    --argjson verification "$STORY_VERIFICATION" \
    --arg prdRef "$PRD_MD_REF" \
    --argjson tasks "$TASKS_JSON" \
    '{
      "version": 1,
      "project": $project,
      "storyId": $storyId,
      "title": $title,
      "description": $description,
      "branchName": $branchName,
      "sprint": $sprint,
      "priority": $priority,
      "depends_on": $depends,
      "status": $status,
      "spec": {
        "scope": $scope,
        "out_of_scope": $outOfScope,
        "first_slice": $firstSlice,
        "preserved_invariants": $invariants,
        "supporting_files": $supporting,
        "verification": $verification,
        "prdRef": $prdRef
      },
      "tasks": $tasks,
      "passes": false
    }')"

  if dry; then
    story_dir_abs="$(dirname "$story_path_abs")"
    if [ "$DRY_RUN" -eq 0 ]; then
      mkdir -p "$story_dir_abs"
      echo "$story_json" > "$story_path_abs"
    fi
    MIGRATED=$((MIGRATED + 1))
    log "    Wrote: $story_path_rel"
    log "    Tasks: $(echo "$TASKS_JSON" | jq 'length') tasks migrated"
  else
    log "    [DRY RUN] Would write: $story_path_rel"
    log "    [DRY RUN] Tasks: $(echo "$TASKS_JSON" | jq 'length') tasks"
    log "    Story JSON preview:"
    echo "$story_json" | jq '.'
  fi
done

# ---------------------------------------------------------------------------
# Write stories.json
# ---------------------------------------------------------------------------

ACTIVE_EPIC_ID="$(jq -r '.activeEpicId // empty' "$EPICS_FILE")"
ACTIVE_STORY_ID=""
[ -n "$ACTIVE_EPIC_ID" ] && ACTIVE_STORY_ID="$(remap_id "$ACTIVE_EPIC_ID")"

stories_json="$(jq -n \
  --argjson version 1 \
  --arg project "$SPRINT_PROJECT" \
  --arg sprint "$TARGET_SPRINT" \
  --argjson capacityTarget "$CAPACITY_TARGET" \
  --argjson capacityCeiling "$CAPACITY_CEILING" \
  --arg activeStoryId "${ACTIVE_STORY_ID:-null}" \
  --argjson stories "$STORIES_ENTRIES" \
  '{
    "version": $version,
    "project": $project,
    "sprint": $sprint,
    "capacityTarget": $capacityTarget,
    "capacityCeiling": $capacityCeiling,
    "activeStoryId": (if $activeStoryId == "null" then null else $activeStoryId end),
    "stories": $stories
  }')"

if [ "$DRY_RUN" -eq 0 ]; then
  echo "$stories_json" > "$STORIES_FILE"
  log ""
  log "Wrote: $STORIES_FILE"
else
  log ""
  log "[DRY RUN] stories.json preview:"
  echo "$stories_json" | jq '.'
fi

log ""
log "=== Migration complete ==="
log "  Migrated: $MIGRATED stories"
log "  Skipped:  $SKIPPED (already had story.json)"
log ""
log "Next steps:"
log "  ./ralph-story.sh list"
log "  ./ralph-story.sh tasks S-001"
log "  ./ralph-task.sh"
