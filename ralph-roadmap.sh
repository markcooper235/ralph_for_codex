#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CODEX_BIN="${CODEX_BIN:-codex}"
ROADMAP_JSON="$SCRIPT_DIR/roadmap.json"
ROADMAP_MD="$SCRIPT_DIR/roadmap.md"
ROADMAP_SOURCE="$SCRIPT_DIR/roadmap-source.md"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
EDITOR_HELPER="$SCRIPT_DIR/lib/editor-intake.sh"
SPRINT_CLI="$SCRIPT_DIR/ralph-sprint.sh"
EPIC_CLI="$SCRIPT_DIR/ralph-epic.sh"

# shellcheck source=./lib/editor-intake.sh
source "$EDITOR_HELPER"

VISION=""
CONSTRAINTS=""
SPRINT_COUNT=3
CAPACITY_TARGET=8
CAPACITY_CEILING=10
QUIET=0
APPLY_ONLY=0
REFINE_MODE=0
REVISION_NOTE=""
ROADMAP_WORK_DIR=""
ROADMAP_JSON_WORK=""
ROADMAP_MD_WORK=""
ROADMAP_SOURCE_WORK=""

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/ralph-roadmap.sh [options]

Create or refine a durable roadmap plan and seed sprint/epic backlogs.

Options:
  --vision TEXT             Roadmap vision / future-state description
  --constraints TEXT        Optional planning constraints
  --refine                  Refine an existing roadmap/source instead of creating the first plan
  --revision-note TEXT      Why the roadmap changed; recorded in roadmap-source.md
  --sprints N               Number of roadmap sprints to plan (default: 3)
  --capacity-target N       Sprint effort target (default: 8)
  --capacity-ceiling N      Sprint effort ceiling (default: 10)
  --apply-only              Apply existing scripts/ralph/roadmap.json without re-planning
  --quiet                   Reduce wrapper output
  -h, --help                Show help

Notes:
  - Each epic effort must be one of: 1, 2, 3, 5
  - Roadmap planning keeps epics sprint-safe; oversized work should roll into later sprints
  - Refinement is additive by default: prefer updating open/future work and adding follow-up epics or sprints over churning completed work
EOF
}

log() {
  if [ "$QUIET" -ne 1 ]; then
    printf '%s\n' "$*"
  fi
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing required command: $1"
  fi
}

setup_work_paths() {
  if [ -n "$ROADMAP_WORK_DIR" ] && [ -d "$ROADMAP_WORK_DIR" ]; then
    return 0
  fi
  ROADMAP_WORK_DIR="$(mktemp -d)"
  ROADMAP_JSON_WORK="$ROADMAP_WORK_DIR/roadmap.json"
  ROADMAP_MD_WORK="$ROADMAP_WORK_DIR/roadmap.md"
  ROADMAP_SOURCE_WORK="$ROADMAP_WORK_DIR/roadmap-source.md"
  trap 'rm -rf "$ROADMAP_WORK_DIR" >/dev/null 2>&1 || true' EXIT
}

supports_codex_yolo() {
  local out
  out="$($CODEX_BIN --yolo exec --help 2>&1 || true)"
  if echo "$out" | grep -qi "unexpected argument '--yolo'"; then
    return 1
  fi
  if echo "$out" | grep -qi "Run Codex non-interactively"; then
    return 0
  fi
  return 1
}

build_codex_exec_args() {
  local -n out_args_ref="$1"
  if supports_codex_yolo; then
    out_args_ref=(--yolo exec -C "$WORKSPACE_ROOT" -)
  else
    out_args_ref=(exec --dangerously-bypass-approvals-and-sandbox -C "$WORKSPACE_ROOT" -)
  fi
}

ensure_clean_worktree() {
  git diff --quiet || fail "Working tree has unstaged changes. Commit or stash them before roadmap planning."
  git diff --cached --quiet || fail "Working tree has staged changes. Commit or stash them before roadmap planning."
}

collect_editor_intake() {
  local intake_file intake_block
  local vision_prefill constraints_prefill note_prefill
  vision_prefill="${VISION:-${CURRENT_SOURCE_VISION:-}}"
  constraints_prefill="${CONSTRAINTS:-${CURRENT_SOURCE_CONSTRAINTS:-}}"
  note_prefill="${REVISION_NOTE:-}"
  intake_file="$(mktemp)"
  cat > "$intake_file" <<EOF
# Ralph Roadmap Intake
#
# Fill in the section below, save, and close your editor.

<!-- BEGIN INPUT -->
VISION:
$vision_prefill

CONSTRAINTS:
$constraints_prefill

REVISION_NOTE:
$note_prefill

<!-- END INPUT -->
EOF
  run_editor_on_file "$intake_file"
  intake_block="$(extract_marked_block "$intake_file" "<!-- BEGIN INPUT -->" "<!-- END INPUT -->")"
  rm -f "$intake_file"

  VISION="$(printf '%s\n' "$intake_block" | awk '
    /^VISION:/ { sub(/^VISION:[[:space:]]*/, ""); in_vision=1; in_constraints=0; print; next }
    /^CONSTRAINTS:/ { in_constraints=1; in_vision=0; next }
    in_vision { print }
  ' | sed '/^[[:space:]]*$/N;/^\n$/D')"
  CONSTRAINTS="$(printf '%s\n' "$intake_block" | awk '
    /^CONSTRAINTS:/ { sub(/^CONSTRAINTS:[[:space:]]*/, ""); in_constraints=1; print; next }
    /^REVISION_NOTE:/ { in_constraints=0; next }
    in_constraints { print }
  ' | sed '/^[[:space:]]*$/N;/^\n$/D')"
  REVISION_NOTE="$(printf '%s\n' "$intake_block" | awk '
    /^REVISION_NOTE:/ { sub(/^REVISION_NOTE:[[:space:]]*/, ""); in_note=1; print; next }
    in_note { print }
  ' | sed '/^[[:space:]]*$/N;/^\n$/D')"
}

read_current_roadmap_source() {
  CURRENT_SOURCE_VISION=""
  CURRENT_SOURCE_CONSTRAINTS=""
  [ -f "$ROADMAP_SOURCE" ] || return 0

  CURRENT_SOURCE_VISION="$(printf '%s\n' "$(
    extract_marked_block "$ROADMAP_SOURCE" "<!-- BEGIN CURRENT -->" "<!-- END CURRENT -->" \
      | awk '
          /^VISION:/ { sub(/^VISION:[[:space:]]*/, ""); in_vision=1; in_constraints=0; in_note=0; print; next }
          /^CONSTRAINTS:/ { in_constraints=1; in_vision=0; in_note=0; next }
          /^REVISION_NOTE:/ { in_note=1; in_vision=0; in_constraints=0; next }
          in_vision { print }
        '
  )" | sed '/^[[:space:]]*$/N;/^\n$/D')"
  CURRENT_SOURCE_CONSTRAINTS="$(printf '%s\n' "$(
    extract_marked_block "$ROADMAP_SOURCE" "<!-- BEGIN CURRENT -->" "<!-- END CURRENT -->" \
      | awk '
          /^CONSTRAINTS:/ { sub(/^CONSTRAINTS:[[:space:]]*/, ""); in_constraints=1; in_vision=0; in_note=0; print; next }
          /^REVISION_NOTE:/ { in_note=1; in_vision=0; in_constraints=0; next }
          in_constraints { print }
        '
  )" | sed '/^[[:space:]]*$/N;/^\n$/D')"
}

write_roadmap_source() {
  local ts history existing_history note
  ts="$(date -Iseconds)"
  note="${REVISION_NOTE:-Initial roadmap creation.}"
  existing_history=""
  if [ -f "$ROADMAP_SOURCE" ]; then
    existing_history="$(awk 'found {print} /^## Revision History$/ {found=1; next}' "$ROADMAP_SOURCE")"
  fi

  {
    printf '# Ralph Roadmap Source\n\n'
    printf 'This is the durable roadmap input. Refine it when the target state changes; downstream sprint and epic plans should reconcile from here.\n\n'
    printf '<!-- BEGIN CURRENT -->\n'
    printf 'VISION:\n%s\n\n' "$VISION"
    printf 'CONSTRAINTS:\n%s\n\n' "${CONSTRAINTS:-Not provided.}"
    printf 'REVISION_NOTE:\n%s\n' "$note"
    printf '<!-- END CURRENT -->\n\n'
    printf '## Revision Policy\n\n'
    printf -- '- Update open and future work directly.\n'
    printf -- '- Treat closed sprints as stable by default.\n'
    printf -- '- Only reopen closed sprints for tightly scoped, low-churn additions.\n'
    printf -- '- Otherwise inject new epics or new sprints for the refinement.\n\n'
    printf '## Revision History\n'
    if [ -n "$existing_history" ]; then
      printf '%s\n' "$existing_history"
    fi
    printf -- '- %s | %s\n' "$ts" "$note"
  } > "$ROADMAP_SOURCE_WORK"
}

plan_roadmap_json() {
  local prompt codex_args=()
  local source_hint refine_hint current_plan_hint backlog_hint
  source_hint="Create the first roadmap plan from the durable source inputs."
  refine_hint=""
  current_plan_hint=""
  backlog_hint=""

  if [ "$REFINE_MODE" -eq 1 ]; then
    source_hint="This is a roadmap refinement. Update the roadmap while preserving traceability to the current source and backlog."
    refine_hint=$(
      cat <<EOF
- Source file: \`scripts/ralph/roadmap-source.md\`
- Current roadmap file: \`scripts/ralph/roadmap.json\`
- Revision note: ${REVISION_NOTE:-none}
EOF
    )
    if [ -f "$ROADMAP_JSON" ]; then
      current_plan_hint="- Current roadmap JSON already exists at \`scripts/ralph/roadmap.json\`."
    fi
    backlog_hint="- Existing sprint backlogs may already contain active or completed epics. Prefer additive updates over churn."
  fi

  mkdir -p "$SCRIPT_DIR"

  prompt=$(
    cat <<EOF
Use the \`prd\` skill.

Create a roadmap plan and write valid JSON to \`$ROADMAP_JSON_WORK\`.

Inputs:
- Project: \`$(basename "$WORKSPACE_ROOT")\`
- Vision: $VISION
- Constraints: ${CONSTRAINTS:-none}
- Source policy: $source_hint
$refine_hint
$current_plan_hint
$backlog_hint
- Sprint count: $SPRINT_COUNT
- Sprint effort target: $CAPACITY_TARGET
- Sprint effort ceiling: $CAPACITY_CEILING

Requirements:
1. Output JSON with keys: project, visionSummary, constraintsSummary, capacityTarget, capacityCeiling, sprints.
2. Create exactly $SPRINT_COUNT sprints named \`sprint-1\` through \`sprint-$SPRINT_COUNT\`.
3. Each sprint object must contain: name, goal, capacityTarget, capacityCeiling, epics.
4. Each epic must contain: id, title, priority, effort, dependsOn, goal, promptContext.
5. Epic effort must be one of: 1, 2, 3, 5.
6. Keep each sprint at or under the capacity ceiling; if more work exists, roll overflow into later sprints.
7. If any epic would be too large for a sprint-safe PRD later, split it now instead of creating an oversized epic.
8. Use \`dependsOn\` only for dependencies inside the same sprint. Express cross-sprint sequencing by sprint order, not cross-sprint dependency links.
9. Write execution-oriented \`promptContext\` that is specific enough for later PRD generation.
10. Treat closed/completed sprints as stable by default. Only place new work into a closed sprint when it is tightly scoped and likely lower churn than adding a follow-up epic or sprint.
11. Prefer additive follow-up epics or new sprints over reopening completed work when the refinement would otherwise cause broad refactor churn.
12. Preserve stable epic IDs for unchanged work when refining; use new IDs for genuinely new follow-up work.
13. Do not create runtime files or PRD JSON. This is planning only.

Return only a short summary after writing the file.
EOF
  )

  build_codex_exec_args codex_args
  printf '%s\n' "$prompt" | "$CODEX_BIN" "${codex_args[@]}"
}

validate_roadmap_json() {
  [ -f "$ROADMAP_JSON_WORK" ] || fail "Roadmap JSON was not created: $ROADMAP_JSON_WORK"
  jq -e \
    --argjson sprintCount "$SPRINT_COUNT" \
    --argjson target "$CAPACITY_TARGET" \
    --argjson ceiling "$CAPACITY_CEILING" '
    .project and
    .visionSummary and
    .capacityTarget == $target and
    .capacityCeiling == $ceiling and
    (.sprints | type == "array") and
    (.sprints | length == $sprintCount) and
    all(.sprints[];
      .name and .goal and
      .capacityTarget == $target and
      .capacityCeiling == $ceiling and
      (.epics | type == "array") and
      ([.epics[]?.effort] | all(. == 1 or . == 2 or . == 3 or . == 5))
    )
  ' "$ROADMAP_JSON_WORK" >/dev/null 2>&1 || fail "Invalid roadmap JSON structure: $ROADMAP_JSON_WORK"

  jq -e '
    [ .sprints[].epics[].id ] as $ids
    | ($ids | unique | length) == ($ids | length)
  ' "$ROADMAP_JSON_WORK" >/dev/null 2>&1 || fail "Roadmap JSON contains duplicate epic IDs."

  jq -e '
    .sprints
    | all(.[]; ([.epics[]?.effort] | add // 0) <= .capacityCeiling)
  ' "$ROADMAP_JSON_WORK" >/dev/null 2>&1 || fail "Roadmap JSON exceeds sprint capacity ceiling."
  validate_sprint_local_dependencies
}

validate_sprint_local_dependencies() {
  local sprint local_ids dep_line epic_id dep_id
  while IFS= read -r sprint; do
    [ -n "$sprint" ] || continue
    local_ids="$(jq -r --arg sprint "$sprint" '.sprints[] | select(.name == $sprint) | .epics[]?.id' "$ROADMAP_JSON_WORK")"
    while IFS=$'\t' read -r epic_id dep_id; do
      [ -n "$epic_id" ] || continue
      [ -n "$dep_id" ] || continue
      if ! printf '%s\n' "$local_ids" | grep -qx "$dep_id"; then
        fail "Roadmap JSON contains cross-sprint or missing dependency: $epic_id -> $dep_id"
      fi
    done < <(jq -r --arg sprint "$sprint" '
      .sprints[]
      | select(.name == $sprint)
      | .epics[]
      | .id as $id
      | (.dependsOn // [])[]
      | [$id, .] | @tsv
    ' "$ROADMAP_JSON_WORK")
  done < <(jq -r '.sprints[].name' "$ROADMAP_JSON_WORK")
}

render_roadmap_markdown() {
  jq -r '
    "# Ralph Roadmap\n\n" +
    "## Vision\n\n" + .visionSummary + "\n\n" +
    "## Constraints\n\n" + (.constraintsSummary // "None provided.") + "\n\n" +
    "Source of truth: `scripts/ralph/roadmap-source.md`\n\n" +
    "## Capacity Policy\n\n" +
    "- Sprint target effort: \(.capacityTarget)\n" +
    "- Sprint ceiling effort: \(.capacityCeiling)\n" +
    "- Epic effort scale: 1, 2, 3, 5\n" +
    "- Cross-sprint sequencing is expressed by sprint order; \u0060dependsOn\u0060 is sprint-local only.\n\n" +
    (
      .sprints
      | map(
          "## " + .name + "\n\n" +
          "Goal: " + .goal + "\n\n" +
          "Planned effort: " + (([.epics[]?.effort] | add // 0) | tostring) + "/" + (.capacityCeiling | tostring) + "\n\n" +
          (
            .epics
            | sort_by(.priority, .id)
            | map(
                "- **" + .id + "** (P" + (.priority | tostring) + " E" + (.effort | tostring) + ") " + .title +
                if ((.dependsOn // []) | length) > 0 then " | depends on: " + ((.dependsOn // []) | join(", ")) else "" end
              )
            | join("\n")
          ) + "\n"
        )
      | join("\n")
    )
  ' "$ROADMAP_JSON_WORK" > "$ROADMAP_MD_WORK"
}

ensure_empty_sprint_backlog() {
  local sprint="$1"
  local epics_file="$SCRIPT_DIR/sprints/$sprint/epics.json"
  [ -f "$epics_file" ] || return 0
  if jq -e '(.epics | length) == 0' "$epics_file" >/dev/null 2>&1; then
    return 0
  fi
  if is_seed_example_backlog "$epics_file"; then
    reset_seed_example_backlog "$epics_file" "$sprint"
    return 0
  fi
  fail "Sprint backlog already has epics: $epics_file"
}

is_seed_example_backlog() {
  local epics_file="$1"
  jq -e '
    (.epics | length) == 2 and
    .epics[0].title == "Foundation Epic" and
    .epics[1].title == "Follow-on Epic"
  ' "$epics_file" >/dev/null 2>&1
}

reset_seed_example_backlog() {
  local epics_file="$1"
  local sprint="$2"
  local tmp_file
  tmp_file="$(mktemp)"
  jq --arg sprint "$sprint" --arg project "$(basename "$WORKSPACE_ROOT")" '
    .project = $project
    | .sprint = $sprint
    | .activeEpicId = null
    | .epics = []
  ' "$epics_file" > "$tmp_file"
  mv "$tmp_file" "$epics_file"
}

ensure_sprint_structure_local() {
  local sprint="$1"
  local epics_file="$SCRIPT_DIR/sprints/$sprint/epics.json"
  mkdir -p "$SCRIPT_DIR/sprints/$sprint" "$SCRIPT_DIR/tasks/$sprint" "$SCRIPT_DIR/tasks/archive/$sprint"
  if [ ! -f "$epics_file" ]; then
    cat > "$epics_file" <<JSON
{
  "version": 1,
  "project": "$(basename "$WORKSPACE_ROOT")",
  "sprint": "$sprint",
  "capacityTarget": $CAPACITY_TARGET,
  "capacityCeiling": $CAPACITY_CEILING,
  "activeEpicId": null,
  "epics": []
}
JSON
  fi
}

write_sprint_capacity_metadata() {
  local sprint="$1"
  local epics_file="$SCRIPT_DIR/sprints/$sprint/epics.json"
  local tmp_file
  tmp_file="$(mktemp)"
  jq --arg sprint "$sprint" --argjson target "$CAPACITY_TARGET" --argjson ceiling "$CAPACITY_CEILING" '
    .sprint = $sprint
    | .capacityTarget = $target
    | .capacityCeiling = $ceiling
  ' "$epics_file" > "$tmp_file"
  mv "$tmp_file" "$epics_file"
}

epic_exists_in_backlog() {
  local epics_file="$1"
  local epic_id="$2"
  jq -e --arg id "$epic_id" '.epics[] | select(.id == $id)' "$epics_file" >/dev/null 2>&1
}

get_epic_status_from_backlog() {
  local epics_file="$1"
  local epic_id="$2"
  jq -r --arg id "$epic_id" '.epics[] | select(.id == $id) | (.status // "planned")' "$epics_file"
}

upsert_epic_metadata() {
  local epics_file="$1"
  local epic_json="$2"
  local epic_id status tmp_file
  epic_id="$(printf '%s\n' "$epic_json" | jq -r '.id')"
  status="$(get_epic_status_from_backlog "$epics_file" "$epic_id")"

  case "$status" in
    done|abandoned|active)
      return 0
      ;;
  esac

  tmp_file="$(mktemp)"
  jq --argjson epic "$epic_json" '
    .epics = (
      .epics
      | map(
          if .id == $epic.id then
            .title = $epic.title
            | .priority = $epic.priority
            | .effort = $epic.effort
            | .dependsOn = ($epic.dependsOn // [])
            | .goal = $epic.goal
            | .promptContext = $epic.promptContext
          else
            .
          end
        )
    )
  ' "$epics_file" > "$tmp_file"
  mv "$tmp_file" "$epics_file"
}

reconcile_sprint_backlog() {
  local sprint_name="$1"
  local epics_file="$SCRIPT_DIR/sprints/$sprint_name/epics.json"
  local epic_json epic_id title priority effort goal prompt_context depends_csv

  while IFS= read -r epic_json; do
    [ -n "$epic_json" ] || continue
    epic_id="$(printf '%s\n' "$epic_json" | jq -r '.id')"
    title="$(printf '%s\n' "$epic_json" | jq -r '.title')"
    priority="$(printf '%s\n' "$epic_json" | jq -r '.priority')"
    effort="$(printf '%s\n' "$epic_json" | jq -r '.effort')"
    goal="$(printf '%s\n' "$epic_json" | jq -r '.goal')"
    prompt_context="$(printf '%s\n' "$epic_json" | jq -r '.promptContext')"
    depends_csv="$(printf '%s\n' "$epic_json" | jq -r '(.dependsOn // []) | join(",")')"

    if epic_exists_in_backlog "$epics_file" "$epic_id"; then
      upsert_epic_metadata "$epics_file" "$epic_json"
    else
      RALPH_EPICS_FILE="$epics_file" "$EPIC_CLI" add \
        --id "$epic_id" \
        --title "$title" \
        --priority "$priority" \
        --effort "$effort" \
        --depends-on "$depends_csv" \
        --goal "$goal" \
        --prompt-context "$prompt_context" >/dev/null
    fi
  done < <(jq -c --arg sprint "$sprint_name" '.sprints[] | select(.name == $sprint) | .epics[]' "$ROADMAP_JSON_WORK")
}

apply_roadmap_to_sprints() {
  local first_sprint=""
  local sprint_count sprint_name sprint_goal epics_file

  sprint_count="$(jq '.sprints | length' "$ROADMAP_JSON_WORK")"
  [ "$sprint_count" -gt 0 ] || fail "Roadmap has no sprints to apply."

  while IFS=$'\t' read -r sprint_name sprint_goal; do
    [ -n "$sprint_name" ] || continue
    if [ -z "$first_sprint" ]; then
      first_sprint="$sprint_name"
    fi

    if [ -f "$SCRIPT_DIR/sprints/$sprint_name/epics.json" ]; then
      if [ "$REFINE_MODE" -eq 1 ]; then
        if is_seed_example_backlog "$SCRIPT_DIR/sprints/$sprint_name/epics.json"; then
          reset_seed_example_backlog "$SCRIPT_DIR/sprints/$sprint_name/epics.json" "$sprint_name"
        fi
      else
        ensure_empty_sprint_backlog "$sprint_name"
      fi
    else
      ensure_sprint_structure_local "$sprint_name"
    fi
    ensure_sprint_structure_local "$sprint_name"
    "$SPRINT_CLI" branch "$sprint_name" >/dev/null
    write_sprint_capacity_metadata "$sprint_name"
    epics_file="$SCRIPT_DIR/sprints/$sprint_name/epics.json"
    reconcile_sprint_backlog "$sprint_name"
  done < <(jq -r '.sprints[] | [.name, .goal] | @tsv' "$ROADMAP_JSON_WORK")

  if [ -n "$first_sprint" ]; then
    printf '%s\n' "$first_sprint" > "$ACTIVE_SPRINT_FILE"
  fi
}

publish_roadmap_artifacts() {
  [ -f "$ROADMAP_JSON_WORK" ] && cp "$ROADMAP_JSON_WORK" "$ROADMAP_JSON"
  [ -f "$ROADMAP_MD_WORK" ] && cp "$ROADMAP_MD_WORK" "$ROADMAP_MD"
  [ -f "$ROADMAP_SOURCE_WORK" ] && cp "$ROADMAP_SOURCE_WORK" "$ROADMAP_SOURCE"
}

commit_roadmap_artifacts_if_needed() {
  local status_lines
  status_lines="$(git status --porcelain -- "$ROADMAP_JSON" "$ROADMAP_MD" "$ROADMAP_SOURCE" "$SCRIPT_DIR/sprints" || true)"
  [ -n "$status_lines" ] || return 0

  git add -- "$ROADMAP_JSON" "$ROADMAP_MD" "$ROADMAP_SOURCE" "$SCRIPT_DIR/sprints"
  if git diff --cached --quiet; then
    return 0
  fi

  if [ "$REFINE_MODE" -eq 1 ]; then
    git commit -m "chore(ralph): refine roadmap plan" >/dev/null
  else
    git commit -m "chore(ralph): add roadmap plan" >/dev/null
  fi
  log "Committed roadmap plan artifacts."
}

main() {
  require_cmd jq
  require_cmd git
  require_cmd "$CODEX_BIN"

  while [ $# -gt 0 ]; do
    case "$1" in
      --vision)
        VISION="${2:-}"
        shift 2
        ;;
      --constraints)
        CONSTRAINTS="${2:-}"
        shift 2
        ;;
      --refine)
        REFINE_MODE=1
        shift
        ;;
      --revision-note)
        REVISION_NOTE="${2:-}"
        shift 2
        ;;
      --sprints)
        SPRINT_COUNT="${2:-}"
        shift 2
        ;;
      --capacity-target)
        CAPACITY_TARGET="${2:-}"
        shift 2
        ;;
      --capacity-ceiling)
        CAPACITY_CEILING="${2:-}"
        shift 2
        ;;
      --apply-only)
        APPLY_ONLY=1
        shift
        ;;
      --quiet)
        QUIET=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done

  [[ "$SPRINT_COUNT" =~ ^[1-9][0-9]*$ ]] || fail "--sprints must be a positive integer."
  [[ "$CAPACITY_TARGET" =~ ^[1-9][0-9]*$ ]] || fail "--capacity-target must be a positive integer."
  [[ "$CAPACITY_CEILING" =~ ^[1-9][0-9]*$ ]] || fail "--capacity-ceiling must be a positive integer."
  [ "$CAPACITY_TARGET" -le "$CAPACITY_CEILING" ] || fail "--capacity-target must be less than or equal to --capacity-ceiling."

  ensure_clean_worktree
  read_current_roadmap_source
  setup_work_paths

  if [ "$APPLY_ONLY" -ne 1 ]; then
    if [ -z "$VISION" ]; then
      if [ -t 0 ] || [ -t 1 ]; then
        collect_editor_intake
      fi
    fi
    if [ -z "$VISION" ] && [ "$REFINE_MODE" -eq 1 ] && [ -n "${CURRENT_SOURCE_VISION:-}" ]; then
      VISION="$CURRENT_SOURCE_VISION"
    fi
    if [ -z "$CONSTRAINTS" ] && [ "$REFINE_MODE" -eq 1 ] && [ -n "${CURRENT_SOURCE_CONSTRAINTS:-}" ]; then
      CONSTRAINTS="$CURRENT_SOURCE_CONSTRAINTS"
    fi
    [ -n "$VISION" ] || fail "Vision is required. Pass --vision or use interactive editor intake."
    if [ "$REFINE_MODE" -eq 1 ]; then
      [ -f "$ROADMAP_SOURCE" ] || fail "Cannot refine without existing roadmap source: scripts/ralph/roadmap-source.md"
      [ -f "$ROADMAP_JSON" ] || fail "Cannot refine without existing roadmap plan: scripts/ralph/roadmap.json"
    fi
    write_roadmap_source
    plan_roadmap_json
  else
    [ -f "$ROADMAP_JSON" ] || fail "Missing roadmap JSON for --apply-only: $ROADMAP_JSON"
    cp "$ROADMAP_JSON" "$ROADMAP_JSON_WORK"
    [ -f "$ROADMAP_MD" ] && cp "$ROADMAP_MD" "$ROADMAP_MD_WORK"
    [ -f "$ROADMAP_SOURCE" ] && cp "$ROADMAP_SOURCE" "$ROADMAP_SOURCE_WORK"
  fi

  validate_roadmap_json
  render_roadmap_markdown
  apply_roadmap_to_sprints
  publish_roadmap_artifacts
  commit_roadmap_artifacts_if_needed

  log "Roadmap plan ready:"
  log "- Source: scripts/ralph/roadmap-source.md"
  log "- JSON: scripts/ralph/roadmap.json"
  log "- Markdown: scripts/ralph/roadmap.md"
}

main "$@"
