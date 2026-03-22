#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CODEX_BIN="${CODEX_BIN:-codex}"
ROADMAP_JSON="$SCRIPT_DIR/roadmap.json"
ROADMAP_MD="$SCRIPT_DIR/roadmap.md"
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

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/ralph-roadmap.sh [options]

Create a durable roadmap plan and seed sprint/epic backlogs.

Options:
  --vision TEXT             Roadmap vision / future-state description
  --constraints TEXT        Optional planning constraints
  --sprints N               Number of roadmap sprints to plan (default: 3)
  --capacity-target N       Sprint effort target (default: 8)
  --capacity-ceiling N      Sprint effort ceiling (default: 10)
  --apply-only              Apply existing scripts/ralph/roadmap.json without re-planning
  --quiet                   Reduce wrapper output
  -h, --help                Show help

Notes:
  - Each epic effort must be one of: 1, 2, 3, 5
  - Roadmap planning keeps epics sprint-safe; oversized work should roll into later sprints
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
  intake_file="$(mktemp)"
  cat > "$intake_file" <<EOF
# Ralph Roadmap Intake
#
# Fill in the section below, save, and close your editor.

<!-- BEGIN INPUT -->
VISION:

CONSTRAINTS:

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
    in_constraints { print }
  ' | sed '/^[[:space:]]*$/N;/^\n$/D')"
}

plan_roadmap_json() {
  local prompt codex_args=()

  mkdir -p "$SCRIPT_DIR"

  prompt=$(
    cat <<EOF
Use the \`prd\` skill.

Create a roadmap plan and write valid JSON to \`scripts/ralph/roadmap.json\`.

Inputs:
- Project: \`$(basename "$WORKSPACE_ROOT")\`
- Vision: $VISION
- Constraints: ${CONSTRAINTS:-none}
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
10. Do not create runtime files or PRD JSON. This is planning only.

Return only a short summary after writing the file.
EOF
  )

  build_codex_exec_args codex_args
  printf '%s\n' "$prompt" | "$CODEX_BIN" "${codex_args[@]}"
}

validate_roadmap_json() {
  [ -f "$ROADMAP_JSON" ] || fail "Roadmap JSON was not created: $ROADMAP_JSON"
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
  ' "$ROADMAP_JSON" >/dev/null 2>&1 || fail "Invalid roadmap JSON structure: $ROADMAP_JSON"

  jq -e '
    [ .sprints[].epics[].id ] as $ids
    | ($ids | unique | length) == ($ids | length)
  ' "$ROADMAP_JSON" >/dev/null 2>&1 || fail "Roadmap JSON contains duplicate epic IDs."

  jq -e '
    .sprints
    | all(.[]; ([.epics[]?.effort] | add // 0) <= .capacityCeiling)
  ' "$ROADMAP_JSON" >/dev/null 2>&1 || fail "Roadmap JSON exceeds sprint capacity ceiling."
  validate_sprint_local_dependencies
}

validate_sprint_local_dependencies() {
  local sprint local_ids dep_line epic_id dep_id
  while IFS= read -r sprint; do
    [ -n "$sprint" ] || continue
    local_ids="$(jq -r --arg sprint "$sprint" '.sprints[] | select(.name == $sprint) | .epics[]?.id' "$ROADMAP_JSON")"
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
    ' "$ROADMAP_JSON")
  done < <(jq -r '.sprints[].name' "$ROADMAP_JSON")
}

render_roadmap_markdown() {
  jq -r '
    "# Ralph Roadmap\n\n" +
    "## Vision\n\n" + .visionSummary + "\n\n" +
    "## Constraints\n\n" + (.constraintsSummary // "None provided.") + "\n\n" +
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
  ' "$ROADMAP_JSON" > "$ROADMAP_MD"
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

apply_roadmap_to_sprints() {
  local first_sprint=""
  local sprint_count sprint_name sprint_goal
  local epic_json epic_id title priority effort goal prompt_context depends_csv

  sprint_count="$(jq '.sprints | length' "$ROADMAP_JSON")"
  [ "$sprint_count" -gt 0 ] || fail "Roadmap has no sprints to apply."

  while IFS=$'\t' read -r sprint_name sprint_goal; do
    [ -n "$sprint_name" ] || continue
    if [ -z "$first_sprint" ]; then
      first_sprint="$sprint_name"
    fi

    if [ -d "$SCRIPT_DIR/sprints/$sprint_name" ]; then
      ensure_empty_sprint_backlog "$sprint_name"
    else
      "$SPRINT_CLI" create "$sprint_name" </dev/null
    fi
    "$SPRINT_CLI" use "$sprint_name" >/dev/null
    write_sprint_capacity_metadata "$sprint_name"

    while IFS= read -r epic_json; do
      [ -n "$epic_json" ] || continue
      epic_id="$(printf '%s\n' "$epic_json" | jq -r '.id')"
      title="$(printf '%s\n' "$epic_json" | jq -r '.title')"
      priority="$(printf '%s\n' "$epic_json" | jq -r '.priority')"
      effort="$(printf '%s\n' "$epic_json" | jq -r '.effort')"
      goal="$(printf '%s\n' "$epic_json" | jq -r '.goal')"
      prompt_context="$(printf '%s\n' "$epic_json" | jq -r '.promptContext')"
      depends_csv="$(printf '%s\n' "$epic_json" | jq -r '(.dependsOn // []) | join(",")')"

      "$EPIC_CLI" add \
        --id "$epic_id" \
        --title "$title" \
        --priority "$priority" \
        --effort "$effort" \
        --depends-on "$depends_csv" \
        --goal "$goal" \
        --prompt-context "$prompt_context" >/dev/null
    done < <(jq -c --arg sprint "$sprint_name" '.sprints[] | select(.name == $sprint) | .epics[]' "$ROADMAP_JSON")
  done < <(jq -r '.sprints[] | [.name, .goal] | @tsv' "$ROADMAP_JSON")

  [ -n "$first_sprint" ] && "$SPRINT_CLI" use "$first_sprint" >/dev/null
}

commit_roadmap_artifacts_if_needed() {
  local status_lines
  status_lines="$(git status --porcelain -- "$ROADMAP_JSON" "$ROADMAP_MD" "$SCRIPT_DIR/sprints" || true)"
  [ -n "$status_lines" ] || return 0

  git add -- "$ROADMAP_JSON" "$ROADMAP_MD" "$SCRIPT_DIR/sprints"
  if git diff --cached --quiet; then
    return 0
  fi

  git commit -m "chore(ralph): add roadmap plan" >/dev/null
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

  if [ "$APPLY_ONLY" -ne 1 ]; then
    if [ -z "$VISION" ]; then
      if [ -t 0 ] || [ -t 1 ]; then
        collect_editor_intake
      fi
    fi
    [ -n "$VISION" ] || fail "Vision is required. Pass --vision or use interactive editor intake."
    plan_roadmap_json
  else
    [ -f "$ROADMAP_JSON" ] || fail "Missing roadmap JSON for --apply-only: $ROADMAP_JSON"
  fi

  validate_roadmap_json
  render_roadmap_markdown
  apply_roadmap_to_sprints
  commit_roadmap_artifacts_if_needed

  log "Roadmap plan ready:"
  log "- JSON: scripts/ralph/roadmap.json"
  log "- Markdown: scripts/ralph/roadmap.md"
}

main "$@"
