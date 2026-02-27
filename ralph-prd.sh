#!/bin/bash
# PRD bootstrap wrapper for Ralph.
# Minimal by default: collect feature concept (+ optional constraints), then run
# Codex with the PRD and Ralph skills to generate tasks/prd-*.md and prd.json.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CODEX_BIN="${CODEX_BIN:-codex}"
PRD_JSON="${PRD_JSON_PATH:-$SCRIPT_DIR/prd.json}"

QUIET=0
FEATURE_CONCEPT=""
HARD_CONSTRAINTS=""

# Quick question modes: ask (prompt user), on (force), off (skip)
QUICK_QUESTIONS_MODE="ask"

PRIMARY_GOAL="Not provided"
TARGET_USERS="Not provided"
SCOPE_LEVEL="Not provided"

usage() {
  cat <<'USAGE'
Usage: ./ralph-prd.sh [options]

Generate PRD markdown + prd.json via Codex skills.

Options:
  --feature TEXT           Feature concept (skip concept prompt)
  --constraints TEXT       Hard constraints/dependencies (single argument)
  --quick-questions        Force the 3-question clarifier flow
  --no-questions           Skip clarifier questions entirely
  --quiet                  Reduce wrapper output (Codex output still shown)
  -h, --help               Show help

Environment:
  CODEX_BIN                Codex CLI command (default: codex)
  PRD_JSON_PATH            Output path for prd.json (default: <script-dir>/prd.json)
USAGE
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

read_multiline() {
  local label="$1"
  local line
  local output=""
  echo "$label"
  echo "(Finish with an empty line)"
  while IFS= read -r line; do
    [ -z "$line" ] && break
    output+="$line"$'\n'
  done
  printf '%s' "$output"
}

read_choice() {
  local prompt="$1"
  local default="$2"
  local answer
  read -r -p "$prompt [$default]: " answer
  answer="${answer:-$default}"
  printf '%s' "${answer^^}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature)
      FEATURE_CONCEPT="${2:-}"
      shift 2
      ;;
    --constraints)
      HARD_CONSTRAINTS="${2:-}"
      shift 2
      ;;
    --quick-questions)
      QUICK_QUESTIONS_MODE="on"
      shift
      ;;
    --no-questions)
      QUICK_QUESTIONS_MODE="off"
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
      fail "Unknown argument: $1"
      ;;
  esac
done

require_cmd "$CODEX_BIN"
require_cmd jq
require_cmd git

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "This helper must run inside a git repository."
fi

if [ -z "$FEATURE_CONCEPT" ]; then
  FEATURE_CONCEPT="$(read_multiline "Describe the feature/requirement concept")"
fi

if [ -z "$FEATURE_CONCEPT" ]; then
  fail "Feature concept is required."
fi

if [ -z "$HARD_CONSTRAINTS" ]; then
  HARD_CONSTRAINTS="$(read_multiline "Optional hard constraints/dependencies - press Enter to skip")"
fi

ASK_QUICK_QUESTIONS=0
if [ "$QUICK_QUESTIONS_MODE" = "on" ]; then
  ASK_QUICK_QUESTIONS=1
elif [ "$QUICK_QUESTIONS_MODE" = "ask" ] && [ -t 0 ]; then
  local_reply=""
  read -r -p "Answer 3 quick clarifying questions? [y/N]: " local_reply
  case "${local_reply,,}" in
    y|yes)
      ASK_QUICK_QUESTIONS=1
      ;;
  esac
fi

if [ "$ASK_QUICK_QUESTIONS" -eq 1 ]; then
  echo ""
  echo "Quick clarifiers (single-letter answers are fine):"
  echo ""

  echo "1) Primary goal"
  echo "   A. Improve user onboarding"
  echo "   B. Increase user retention"
  echo "   C. Reduce support burden"
  echo "   D. Other"
  goal_choice="$(read_choice "Choice" "A")"
  case "$goal_choice" in
    A) PRIMARY_GOAL="Improve user onboarding" ;;
    B) PRIMARY_GOAL="Increase user retention" ;;
    C) PRIMARY_GOAL="Reduce support burden" ;;
    D)
      read -r -p "Describe goal: " PRIMARY_GOAL
      PRIMARY_GOAL="${PRIMARY_GOAL:-Not provided}"
      ;;
    *) PRIMARY_GOAL="Not provided" ;;
  esac

  echo ""
  echo "2) Target users"
  echo "   A. New users only"
  echo "   B. Existing users only"
  echo "   C. All users"
  echo "   D. Admin users only"
  echo "   E. Other"
  users_choice="$(read_choice "Choice" "C")"
  case "$users_choice" in
    A) TARGET_USERS="New users only" ;;
    B) TARGET_USERS="Existing users only" ;;
    C) TARGET_USERS="All users" ;;
    D) TARGET_USERS="Admin users only" ;;
    E)
      read -r -p "Describe target users: " TARGET_USERS
      TARGET_USERS="${TARGET_USERS:-Not provided}"
      ;;
    *) TARGET_USERS="Not provided" ;;
  esac

  echo ""
  echo "3) Scope level"
  echo "   A. Minimal viable version"
  echo "   B. Full-featured implementation"
  echo "   C. Backend/API only"
  echo "   D. UI only"
  echo "   E. Other"
  scope_choice="$(read_choice "Choice" "A")"
  case "$scope_choice" in
    A) SCOPE_LEVEL="Minimal viable version" ;;
    B) SCOPE_LEVEL="Full-featured implementation" ;;
    C) SCOPE_LEVEL="Backend/API only" ;;
    D) SCOPE_LEVEL="UI only" ;;
    E)
      read -r -p "Describe scope: " SCOPE_LEVEL
      SCOPE_LEVEL="${SCOPE_LEVEL:-Not provided}"
      ;;
    *) SCOPE_LEVEL="Not provided" ;;
  esac
fi

PRD_JSON_REL="$PRD_JSON"
if [[ "$PRD_JSON" == "$WORKSPACE_ROOT/"* ]]; then
  PRD_JSON_REL="${PRD_JSON#$WORKSPACE_ROOT/}"
fi

PROMPT=$(
  cat <<PROMPT_EOF
Use the \`prd\` skill and then the \`ralph\` skill, in that order.

Create a complete Ralph planning package from this feature concept.

Feature concept:
$FEATURE_CONCEPT

Hard constraints/dependencies (if any):
${HARD_CONSTRAINTS:-None provided}

Quick clarifier answers (if provided):
- Primary goal: $PRIMARY_GOAL
- Target users: $TARGET_USERS
- Scope level: $SCOPE_LEVEL

Guidance:
1. Follow the PRD skill workflow. If information is already sufficient, keep clarifying questions minimal.
2. If critical gaps remain, infer using explicit assumptions instead of blocking.
3. Generate a PRD markdown file in \`tasks/prd-[feature-name].md\`.
4. Break work into small, one-iteration user stories ordered by dependency.
5. Set clear story priorities (1..N in execution order).
6. Every story acceptance criteria must include:
   - "Typecheck passes"
   - "Lint passes"
   - "Unit tests pass" (or "Tests pass" only if unit tests are not applicable)
7. For UI stories, include "Verify in browser using dev-browser skill".
8. Convert the PRD to Ralph JSON and write it to \`$PRD_JSON_REL\`.
9. Ensure JSON schema fields: \`project\`, \`branchName\`, \`description\`, \`userStories\`.

Return a short summary with:
- PRD markdown path
- prd.json path
- Number of user stories created
PROMPT_EOF
)

log "Generating PRD and prd.json via Codex skills..."
CODEX_ARGS=()
build_codex_exec_args CODEX_ARGS
printf '%s\n' "$PROMPT" | "$CODEX_BIN" "${CODEX_ARGS[@]}"

if [ ! -f "$PRD_JSON" ]; then
  fail "Expected prd.json at $PRD_JSON"
fi

if ! jq -e '.project and .branchName and .description and (.userStories | length > 0)' "$PRD_JSON" >/dev/null 2>&1; then
  fail "prd.json missing required fields or userStories"
fi

if ! jq -e '
  all(.userStories[];
    any(.acceptanceCriteria[]; test("(?i)typecheck passes")) and
    any(.acceptanceCriteria[]; test("(?i)lint passes")) and
    (
      any(.acceptanceCriteria[]; test("(?i)unit tests pass")) or
      any(.acceptanceCriteria[]; test("(?i)tests pass"))
    )
  )
' "$PRD_JSON" >/dev/null 2>&1; then
  fail "Each story must include typecheck, lint, and tests acceptance criteria"
fi

log "Done."
printf 'PRD JSON: %s\n' "$PRD_JSON"
printf 'Stories: %s\n' "$(jq '.userStories | length' "$PRD_JSON")"
