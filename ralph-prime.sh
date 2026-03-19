#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
ACTIVE_PRD_FILE="$SCRIPT_DIR/.active-prd"
SPRINTS_DIR="$SCRIPT_DIR/sprints"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
EPICS_FILE=""
EPIC_CLI="$SCRIPT_DIR/ralph-epic.sh"
CODEX_BIN="${CODEX_BIN:-codex}"
ACTIVE_SPRINT=""
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
CODEX_LAST_MESSAGE_FILE="$SCRIPT_DIR/.codex-last-message.txt"
WORKSPACE_ROOT_PLAYWRIGHT_DIR="$WORKSPACE_ROOT/.playwright-cli"

AUTO_MODE=0
REGEN_PRD=0
AUTO_COMMIT=0

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/ralph-prime.sh [--auto] [--regen-prd] [--auto-commit]

Behavior:
  - If scripts/ralph/prd.json has unfinished stories, no-op.
  - If prd.json is empty or all stories passed, selects next eligible epic and
    converts its primary PRD markdown into scripts/ralph/prd.json via Codex.
  - If no "next eligible" epic exists, uses the currently active epic when valid.
  - If no eligible epic exists, prompts user to create a new epic or standalone PRD.

Options:
  --auto   Non-interactive mode. If no eligible epic exists, exit non-zero
           with a clear prompt message.
  --regen-prd  If epic has promptContext, regenerate markdown PRD even when file exists.
  --auto-commit  Commit primed epic status change in epics.json after successful priming.
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

get_active_sprint() {
  if [ -f "$ACTIVE_SPRINT_FILE" ]; then
    awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE"
    return 0
  fi
  return 1
}

resolve_epics_file() {
  ACTIVE_SPRINT="$(get_active_sprint || true)"
  if [ -z "$ACTIVE_SPRINT" ]; then
    fail "No active sprint set. Run ./scripts/ralph/ralph-sprint.sh use <sprint-name>."
  fi
  EPICS_FILE="$SPRINTS_DIR/$ACTIVE_SPRINT/epics.json"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing required command: $1"
  fi
}

supports_codex_yolo() {
  local out
  out="$("$CODEX_BIN" --yolo exec --help 2>&1 || true)"
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

is_prd_empty() {
  [ ! -f "$PRD_FILE" ] || [ ! -s "$PRD_FILE" ] || ! grep -q '[^[:space:]]' "$PRD_FILE"
}

prd_is_valid_json() {
  [ -f "$PRD_FILE" ] && jq -e '.' "$PRD_FILE" >/dev/null 2>&1
}

prd_has_unfinished_stories() {
  prd_is_valid_json && jq -e '(.userStories | length) > 0 and any(.userStories[]; .passes != true)' "$PRD_FILE" >/dev/null 2>&1
}

prd_all_passes() {
  prd_is_valid_json && jq -e '(.userStories | length) > 0 and all(.userStories[]; .passes == true)' "$PRD_FILE" >/dev/null 2>&1
}

ensure_transient_files_not_tracked() {
  local tracked
  tracked="$(git ls-files -- "$PRD_FILE" "$SCRIPT_DIR/progress.txt" || true)"
  if [ -n "$tracked" ]; then
    fail "Ralph transient files are tracked in git. Run: git rm --cached scripts/ralph/prd.json scripts/ralph/progress.txt"
  fi
}

find_next_epic_id() {
  [ -f "$EPIC_CLI" ] || return 1
  bash "$EPIC_CLI" next-id 2>/dev/null | head -n 1
}

choose_primary_prd_path_for_epic() {
  local epic_id="$1"
  jq -r --arg id "$epic_id" '
    (.epics[] | select(.id == $id) | (.prdPaths // [])) as $paths
    | (($paths[] | select(test("/prd-epic-"))) // ($paths[0] // empty))
  ' "$EPICS_FILE"
}

get_epic_field() {
  local epic_id="$1"
  local field="$2"
  jq -r --arg id "$epic_id" --arg field "$field" '
    .epics[] | select(.id == $id) | .[$field] // empty
  ' "$EPICS_FILE"
}

get_epic_array_field_joined() {
  local epic_id="$1"
  local field="$2"
  jq -r --arg id "$epic_id" --arg field "$field" '
    .epics[] | select(.id == $id) | (.[$field] // []) | join(", ")
  ' "$EPICS_FILE"
}

get_active_epic_id() {
  jq -r '.activeEpicId // empty' "$EPICS_FILE" 2>/dev/null
}

set_epic_active() {
  local epic_id="$1"
  [ -f "$EPIC_CLI" ] || return 0
  bash "$EPIC_CLI" set-status "$epic_id" active >/dev/null
}

set_active_epic_prd() {
  local epic_id="$1"
  local source_path="$2"
  local base_branch
  base_branch="ralph/sprint/$ACTIVE_SPRINT"
  cat >"$ACTIVE_PRD_FILE" <<EOF
{
  "mode": "epic",
  "epicId": "$epic_id",
  "baseBranch": "$base_branch",
  "sourcePath": "$source_path",
  "activatedAt": "$(date -Iseconds)"
}
EOF
}

commit_primed_epic_state_if_needed() {
  local epic_id="$1"
  local status_line epic_title

  status_line="$(git status --porcelain -- "$EPICS_FILE" || true)"
  [ -n "$status_line" ] || return 0

  if ! jq -e '.epics and (.epics|type=="array")' "$EPICS_FILE" >/dev/null 2>&1; then
    fail "Cannot auto-commit primed epic state: invalid $EPICS_FILE"
  fi

  epic_title="$(jq -r --arg id "$epic_id" '.epics[] | select(.id == $id) | .title // empty' "$EPICS_FILE")"

  git add "$EPICS_FILE"
  if git diff --cached --quiet; then
    return 0
  fi

  git commit -m "chore(ralph): prime $epic_id active for loop startup"
  echo "Committed primed epic state: $epic_id ${epic_title:+- $epic_title}"
}

validate_generated_prd() {
  prd_is_valid_json || return 1
  jq -e '
    (.project | type == "string" and length > 0) and
    (.branchName | type == "string" and length > 0) and
    (.description | type == "string") and
    (.userStories | type == "array" and length > 0)
  ' "$PRD_FILE" >/dev/null 2>&1 || return 1
  return 0
}

reset_local_run_artifacts() {
  local iter_log

  rm -f "$CODEX_LAST_MESSAGE_FILE"
  for iter_log in "$SCRIPT_DIR"/.codex-last-message-iter-*.txt; do
    [ -f "$iter_log" ] || continue
    rm -f "$iter_log"
  done
  [ -d "$WORKSPACE_ROOT_PLAYWRIGHT_DIR" ] && rm -rf "$WORKSPACE_ROOT_PLAYWRIGHT_DIR"

  {
    echo "# Ralph Progress Log"
    echo "Started: $(date)"
    echo "---"
  } > "$PROGRESS_FILE"
}

slugify_branch_segment() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's|[^a-z0-9._-]+|-|g' \
    | sed -E 's|^-+||; s|-+$||'
}

convert_markdown_prd_to_json() {
  local markdown_path="$1"
  local epic_id="$2"
  local sprint_name="$3"
  local prompt codex_args=()
  local epic_slug sprint_slug
  epic_slug="$(slugify_branch_segment "$epic_id")"
  sprint_slug="$(slugify_branch_segment "$sprint_name")"

  prompt=$(
    cat <<EOF
Use the \`ralph\` skill.

Convert this PRD markdown file into Ralph JSON at \`scripts/ralph/prd.json\`:
- Source: \`$markdown_path\`
- Destination: \`scripts/ralph/prd.json\`

Requirements:
1. Produce valid JSON with keys: project, branchName, description, userStories.
2. Set \`branchName\` to: \`ralph/$sprint_slug/$epic_slug\`.
3. Keep user stories small, ordered by dependency, and execution-ready.
4. Include acceptance criteria with typecheck/lint/tests requirements.

Return only a short summary after writing the file.
EOF
  )

  build_codex_exec_args codex_args
  printf '%s\n' "$prompt" | "$CODEX_BIN" "${codex_args[@]}"
}

generate_markdown_prd_from_epic_context() {
  local markdown_path="$1"
  local epic_id="$2"
  local sprint_name="$3"
  local epic_title epic_goal epic_deps epic_open_qs epic_prompt_context
  local prompt sidecar codex_args=()

  epic_title="$(get_epic_field "$epic_id" "title")"
  epic_goal="$(get_epic_field "$epic_id" "goal")"
  epic_deps="$(get_epic_array_field_joined "$epic_id" "dependsOn")"
  epic_open_qs="$(get_epic_array_field_joined "$epic_id" "openQuestions")"
  epic_prompt_context="$(get_epic_field "$epic_id" "promptContext")"

  [ -n "$epic_prompt_context" ] || fail "Epic $epic_id has no promptContext; cannot generate PRD markdown."
  mkdir -p "$(dirname "$WORKSPACE_ROOT/$markdown_path")"

  sidecar="$(mktemp "$SCRIPT_DIR/.epic-prompt-${epic_id}-XXXXXX.md")"
  cat > "$sidecar" <<EOF
# Epic Prompt Context
epic_id: $epic_id
sprint: $sprint_name
title: $epic_title
goal: $epic_goal
depends_on: ${epic_deps:-none}
open_questions: ${epic_open_qs:-none}

## Prompt Conversation / Context
$epic_prompt_context
EOF

  prompt=$(
    cat <<EOF
Use the \`prd\` skill.

Generate a complete PRD markdown from this epic context and write it to:
\`$markdown_path\`

Inputs:
- Epic ID: $epic_id
- Sprint: $sprint_name
- Title: $epic_title
- Goal: $epic_goal
- Depends on: ${epic_deps:-none}
- Open questions: ${epic_open_qs:-none}
- Prompt context sidecar: \`${sidecar#$WORKSPACE_ROOT/}\`

Requirements:
1. Output must be a complete PRD markdown suitable for later Ralph JSON conversion.
2. Keep stories small, ordered by dependency, with clear acceptance criteria.
3. Include explicit assumptions where context is ambiguous.
4. Overwrite destination if it exists.

Return a short summary and the exact output path.
EOF
  )

  build_codex_exec_args codex_args
  if printf '%s\n' "$prompt" | "$CODEX_BIN" "${codex_args[@]}"; then
    rm -f "$sidecar"
    return 0
  fi

  echo "PRD markdown generation failed for $epic_id. Prompt sidecar kept at: $sidecar" >&2
  return 1
}

prompt_no_eligible_epic() {
  local message="No eligible next epic found in active sprint epics.json. Do you want to create (1) a new Epic or (2) a stand-alone PRD to prime the loop?"
  if [ "$AUTO_MODE" -eq 1 ] || [ ! -t 0 ]; then
    fail "$message"
  fi

  echo "$message"
  read -r -p "Enter 1 or 2 (or anything else to cancel): " choice
  case "$choice" in
    1)
      echo "Create a new epic entry in the active sprint epics.json, then rerun ./scripts/ralph/ralph-prime.sh."
      ;;
    2)
      echo "Create/convert a stand-alone PRD into scripts/ralph/prd.json (e.g., ./scripts/ralph/ralph-prd.sh), then rerun the loop."
      ;;
    *)
      echo "Canceled."
      ;;
  esac
  exit 1
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto)
        AUTO_MODE=1
        shift
        ;;
      --regen-prd)
        REGEN_PRD=1
        shift
        ;;
      --auto-commit)
        AUTO_COMMIT=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done

  require_cmd jq
  require_cmd sed
  require_cmd tr
  require_cmd git
  require_cmd "$CODEX_BIN"
  resolve_epics_file
  ensure_transient_files_not_tracked

  # In non-interactive/automation mode, default to committing primed epic state.
  if [ "$AUTO_MODE" -eq 1 ] && [ "$AUTO_COMMIT" -eq 0 ]; then
    AUTO_COMMIT=1
  fi

  if prd_has_unfinished_stories; then
    echo "PRD already has unfinished stories; keeping current scripts/ralph/prd.json."
    exit 0
  fi

  if [ ! -f "$EPICS_FILE" ] || ! jq -e '.epics and (.epics|type=="array")' "$EPICS_FILE" >/dev/null 2>&1; then
    if is_prd_empty || prd_all_passes; then
      fail "No valid epics backlog and current prd.json is empty/completed. Create a new epic or standalone PRD first."
    fi
    echo "No valid epics backlog found; leaving current PRD as-is."
    exit 0
  fi

  local next_epic source_mode
  source_mode="next-eligible"
  next_epic="$(find_next_epic_id || true)"
  if [ -z "$next_epic" ]; then
    local active_epic active_status
    active_epic="$(get_active_epic_id)"
    active_status=""
    if [ -n "$active_epic" ]; then
      active_status="$(jq -r --arg id "$active_epic" '.epics[] | select(.id == $id) | .status // empty' "$EPICS_FILE")"
    fi
    if [ -n "$active_epic" ] && [ "$active_status" = "active" ]; then
      next_epic="$active_epic"
      source_mode="active-epic-fallback"
      echo "No eligible next epic found; using active epic $next_epic."
    else
      prompt_no_eligible_epic
    fi
  fi

  local source_prd
  source_prd="$(choose_primary_prd_path_for_epic "$next_epic")"
  if [ -z "$source_prd" ]; then
    fail "Epic $next_epic has no PRD path configured."
  fi

  local epic_prompt_context
  epic_prompt_context="$(get_epic_field "$next_epic" "promptContext")"
  if [ -n "$epic_prompt_context" ] && { [ "$REGEN_PRD" -eq 1 ] || [ ! -f "$WORKSPACE_ROOT/$source_prd" ]; }; then
    echo "Generating PRD markdown from epic context for $next_epic ..."
    generate_markdown_prd_from_epic_context "$source_prd" "$next_epic" "$ACTIVE_SPRINT" || fail "Failed generating markdown PRD for $next_epic"
  fi

  if [ ! -f "$WORKSPACE_ROOT/$source_prd" ]; then
    fail "Epic source PRD not found and no promptContext generation available: $source_prd"
  fi

  echo "Priming Ralph from $next_epic using $source_prd (source=$source_mode) ..."
  convert_markdown_prd_to_json "$source_prd" "$next_epic" "$ACTIVE_SPRINT"

  if ! validate_generated_prd; then
    fail "Generated PRD JSON missing required structure: $PRD_FILE"
  fi

  # Mark active only after PRD conversion/validation succeeds.
  set_epic_active "$next_epic"
  set_active_epic_prd "$next_epic" "$source_prd"
  reset_local_run_artifacts
  if [ "$AUTO_COMMIT" -eq 1 ]; then
    commit_primed_epic_state_if_needed "$next_epic"
  fi

  local remaining
  remaining="$(jq -r '([.userStories[] | select(.passes != true)] | length)' "$PRD_FILE")"
  echo "Primed scripts/ralph/prd.json with $remaining remaining stories from $next_epic."
}

main "$@"
