#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
EPICS_FILE="$SCRIPT_DIR/epics.json"
EPIC_CLI="$SCRIPT_DIR/ralph-epic.sh"
CODEX_BIN="${CODEX_BIN:-codex}"

AUTO_MODE=0

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/ralph-prime.sh [--auto]

Behavior:
  - If scripts/ralph/prd.json has unfinished stories, no-op.
  - If prd.json is empty or all stories passed, selects next eligible epic and
    converts its primary PRD markdown into scripts/ralph/prd.json via Codex.
  - If no eligible epic exists, prompts user to create a new epic or standalone PRD.

Options:
  --auto   Non-interactive mode. If no eligible epic exists, exit non-zero
           with a clear prompt message.
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
  bash "$EPIC_CLI" next 2>/dev/null | sed -n 's/^Next epic: \([^ ]*\).*/\1/p' | head -n 1
}

choose_primary_prd_path_for_epic() {
  local epic_id="$1"
  jq -r --arg id "$epic_id" '
    (.epics[] | select(.id == $id) | (.prdPaths // [])) as $paths
    | (($paths[] | select(test("^tasks/prd-epic-"))) // ($paths[0] // empty))
  ' "$EPICS_FILE"
}

set_epic_active() {
  local epic_id="$1"
  [ -f "$EPIC_CLI" ] || return 0
  bash "$EPIC_CLI" set-status "$epic_id" active >/dev/null
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

slugify_branch_segment() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's|[^a-z0-9._-]+|-|g' \
    | sed -E 's|^-+||; s|-+$||'
}

convert_markdown_prd_to_json() {
  local markdown_path="$1"
  local epic_id="$2"
  local prompt codex_args=()
  local epic_slug
  epic_slug="$(slugify_branch_segment "$epic_id")"

  prompt=$(
    cat <<EOF
Use the \`ralph\` skill.

Convert this PRD markdown file into Ralph JSON at \`scripts/ralph/prd.json\`:
- Source: \`$markdown_path\`
- Destination: \`scripts/ralph/prd.json\`

Requirements:
1. Produce valid JSON with keys: project, branchName, description, userStories.
2. Set \`branchName\` to: \`ralph/$epic_slug\`.
3. Keep user stories small, ordered by dependency, and execution-ready.
4. Include acceptance criteria with typecheck/lint/tests requirements.

Return only a short summary after writing the file.
EOF
  )

  build_codex_exec_args codex_args
  printf '%s\n' "$prompt" | "$CODEX_BIN" "${codex_args[@]}"
}

prompt_no_eligible_epic() {
  local message="No eligible next epic found in scripts/ralph/epics.json. Do you want to create (1) a new Epic or (2) a stand-alone PRD to prime the loop?"
  if [ "$AUTO_MODE" -eq 1 ] || [ ! -t 0 ]; then
    fail "$message"
  fi

  echo "$message"
  read -r -p "Enter 1 or 2 (or anything else to cancel): " choice
  case "$choice" in
    1)
      echo "Create a new epic entry in scripts/ralph/epics.json, then rerun ./scripts/ralph/ralph-prime.sh."
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
  ensure_transient_files_not_tracked

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

  local next_epic
  next_epic="$(find_next_epic_id)"
  if [ -z "$next_epic" ]; then
    prompt_no_eligible_epic
  fi

  local source_prd
  source_prd="$(choose_primary_prd_path_for_epic "$next_epic")"
  if [ -z "$source_prd" ]; then
    fail "Epic $next_epic has no PRD path configured."
  fi
  if [ ! -f "$WORKSPACE_ROOT/$source_prd" ]; then
    fail "Epic source PRD not found: $source_prd"
  fi

  echo "Priming Ralph from $next_epic using $source_prd ..."
  set_epic_active "$next_epic"
  convert_markdown_prd_to_json "$source_prd" "$next_epic"

  if ! validate_generated_prd; then
    fail "Generated PRD JSON missing required structure: $PRD_FILE"
  fi

  local remaining
  remaining="$(jq -r '([.userStories[] | select(.passes != true)] | length)' "$PRD_FILE")"
  echo "Primed scripts/ralph/prd.json with $remaining remaining stories from $next_epic."
}

main "$@"
