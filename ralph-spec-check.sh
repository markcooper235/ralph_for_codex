#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$WORKSPACE_ROOT" ]; then
  WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/ralph-spec-check.sh <prd-markdown-path>

Checks whether a PRD markdown file is loop-ready for Ralph.
Returns:
  0 when the spec passes
  1 when the spec is weak and should be strengthened
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

section_exists() {
  local heading="$1"
  local file="$2"
  rg -q "^## ${heading}\$" "$file"
}

count_story_headings() {
  local file="$1"
  rg -c '^### Story ' "$file"
}

count_acceptance_headings() {
  local file="$1"
  rg -c '^Acceptance Criteria$' "$file"
}

count_must_bullets() {
  local file="$1"
  rg -c '^- Must ' "$file"
}

section_body() {
  local heading="$1"
  local file="$2"
  awk -v heading="## ${heading}" '
    $0 == heading { in_section=1; next }
    /^## / && in_section { exit }
    in_section { print }
  ' "$file"
}

report_issue() {
  local issue="$1"
  printf 'FAIL: %s\n' "$issue"
}

main() {
  local file story_count acceptance_count must_count issue_count first_slice_body execution_body allowed_body invariants_body

  case "${1:-}" in
    -h|--help|help)
      usage
      exit 0
      ;;
    "")
      fail "Missing PRD markdown path"
      ;;
  esac

  file="$1"
  if [[ "$file" != /* ]]; then
    file="$WORKSPACE_ROOT/$file"
  fi

  [ -f "$file" ] || fail "Missing file: $file"
  [ -s "$file" ] || fail "Empty file: $file"

  issue_count=0

  for heading in "Scope" "Out of Scope" "Execution Model" "First Slice Expectations" "Allowed Supporting Files" "Preserved Invariants" "User Stories" "Refinement Checkpoints" "Definition of Done"; do
    if ! section_exists "$heading" "$file"; then
      report_issue "Missing required section: ## $heading"
      issue_count=$((issue_count + 1))
    fi
  done

  story_count="$(count_story_headings "$file")"
  if [ "$story_count" -lt 1 ] || [ "$story_count" -gt 6 ]; then
    report_issue "Story count must be between 1 and 6; found $story_count"
    issue_count=$((issue_count + 1))
  fi

  acceptance_count="$(count_acceptance_headings "$file")"
  if [ "$acceptance_count" -lt "$story_count" ]; then
    report_issue "Each story needs an Acceptance Criteria block; found $acceptance_count for $story_count stories"
    issue_count=$((issue_count + 1))
  fi

  must_count="$(count_must_bullets "$file")"
  if [ "$must_count" -lt $((story_count * 3)) ]; then
    report_issue "Acceptance criteria are too thin; expected at least $((story_count * 3)) '- Must' bullets, found $must_count"
    issue_count=$((issue_count + 1))
  fi

  execution_body="$(section_body "Execution Model" "$file")"
  if ! printf '%s\n' "$execution_body" | rg -qi 'first slice|support|scope|verify|verification'; then
    report_issue "Execution Model must describe slice order, supporting scope, or verification pressure"
    issue_count=$((issue_count + 1))
  fi

  first_slice_body="$(section_body "First Slice Expectations" "$file")"
  if ! printf '%s\n' "$first_slice_body" | rg -qi 'exact source|destination|entrypoint|caller migration|caller set|workflow|commands'; then
    report_issue "First Slice Expectations must name exact source/destination/caller or workflow/command details"
    issue_count=$((issue_count + 1))
  fi

  allowed_body="$(section_body "Allowed Supporting Files" "$file")"
  if ! printf '%s\n' "$allowed_body" | rg -qi 'project\.json|nx\.json|package\.json|lint|test|verify|workflow|config|script'; then
    report_issue "Allowed Supporting Files must proactively name realistic support file families"
    issue_count=$((issue_count + 1))
  fi

  invariants_body="$(section_body "Preserved Invariants" "$file")"
  if ! printf '%s\n' "$invariants_body" | rg -qi 'remain|preserve|unchanged|mandatory|canonical|intact|stable'; then
    report_issue "Preserved Invariants must name behaviors or rules that cannot drift"
    issue_count=$((issue_count + 1))
  fi

  if rg -qi 'where appropriate|as needed|if helpful|if applicable' "$file"; then
    report_issue "Spec still contains vague guidance phrases that often cause loop churn"
    issue_count=$((issue_count + 1))
  fi

  if [ "$issue_count" -gt 0 ]; then
    exit 1
  fi

  printf 'PASS: %s is loop-ready\n' "${file#$WORKSPACE_ROOT/}"
}

main "$@"
