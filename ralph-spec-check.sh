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

has_rg() {
  command -v rg >/dev/null 2>&1
}

section_exists() {
  local heading="$1"
  local file="$2"
  if has_rg; then
    rg -q "^## ${heading}\$" "$file"
  else
    grep -Eq "^## ${heading}\$" "$file"
  fi
}

count_story_headings() {
  local file="$1"
  if has_rg; then
    rg -c '^### Story ' "$file" || printf '0\n'
  else
    grep -Ec '^### Story ' "$file" || true
  fi
}

count_acceptance_headings() {
  local file="$1"
  if has_rg; then
    rg -c '^Acceptance Criteria$' "$file" || printf '0\n'
  else
    grep -Ec '^Acceptance Criteria$' "$file" || true
  fi
}

count_must_bullets() {
  local file="$1"
  if has_rg; then
    rg -c '^- Must ' "$file" || printf '0\n'
  else
    grep -Ec '^- Must ' "$file" || true
  fi
}

count_matching_lines() {
  local pattern="$1"
  local file="$2"
  if has_rg; then
    rg -c "$pattern" "$file" || printf '0\n'
  else
    grep -Ec "$pattern" "$file" || true
  fi
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
  local proof_count first_slice_detail_groups execution_detail_groups invariant_bullets checkpoint_bullets

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

  proof_count="$(count_matching_lines '^- Must .*(Typecheck passes|Lint passes|Unit tests pass|Tests pass|Verify in browser|Playwright|Cypress|verification)' "$file")"
  if [ "$proof_count" -lt "$story_count" ]; then
    report_issue "Each story needs at least one explicit proof obligation; found $proof_count proof bullets for $story_count stories"
    issue_count=$((issue_count + 1))
  fi

  execution_body="$(section_body "Execution Model" "$file")"
  execution_detail_groups=0
  if has_rg; then
    if printf '%s\n' "$execution_body" | rg -qi 'first slice|sequence|order|dependency'; then
      execution_detail_groups=$((execution_detail_groups + 1))
    fi
    if printf '%s\n' "$execution_body" | rg -qi 'support|scope|supporting'; then
      execution_detail_groups=$((execution_detail_groups + 1))
    fi
    if printf '%s\n' "$execution_body" | rg -qi 'verify|verification|proof|targeted|full'; then
      execution_detail_groups=$((execution_detail_groups + 1))
    fi
  else
    if printf '%s\n' "$execution_body" | grep -Eqi 'first slice|sequence|order|dependency'; then
      execution_detail_groups=$((execution_detail_groups + 1))
    fi
    if printf '%s\n' "$execution_body" | grep -Eqi 'support|scope|supporting'; then
      execution_detail_groups=$((execution_detail_groups + 1))
    fi
    if printf '%s\n' "$execution_body" | grep -Eqi 'verify|verification|proof|targeted|full'; then
      execution_detail_groups=$((execution_detail_groups + 1))
    fi
  fi
  if [ "$execution_detail_groups" -lt 2 ]; then
    report_issue "Execution Model must cover at least two of: slice order, supporting scope, verification pressure"
    issue_count=$((issue_count + 1))
  fi

  first_slice_body="$(section_body "First Slice Expectations" "$file")"
  first_slice_detail_groups=0
  if has_rg; then
    if printf '%s\n' "$first_slice_body" | rg -qi 'exact source|destination'; then
      first_slice_detail_groups=$((first_slice_detail_groups + 1))
    fi
    if printf '%s\n' "$first_slice_body" | rg -qi 'entrypoint|caller migration|caller set|workflow|commands'; then
      first_slice_detail_groups=$((first_slice_detail_groups + 1))
    fi
  else
    if printf '%s\n' "$first_slice_body" | grep -Eqi 'exact source|destination'; then
      first_slice_detail_groups=$((first_slice_detail_groups + 1))
    fi
    if printf '%s\n' "$first_slice_body" | grep -Eqi 'entrypoint|caller migration|caller set|workflow|commands'; then
      first_slice_detail_groups=$((first_slice_detail_groups + 1))
    fi
  fi
  if [ "$first_slice_detail_groups" -lt 2 ]; then
    report_issue "First Slice Expectations must name exact source/destination details and caller/workflow details"
    issue_count=$((issue_count + 1))
  fi

  allowed_body="$(section_body "Allowed Supporting Files" "$file")"
  if has_rg; then
    if ! printf '%s\n' "$allowed_body" | rg -qi 'project\.json|nx\.json|package\.json|lint|test|verify|workflow|config|script'; then
      report_issue "Allowed Supporting Files must proactively name realistic support file families"
      issue_count=$((issue_count + 1))
    fi
  elif ! printf '%s\n' "$allowed_body" | grep -Eqi 'project\.json|nx\.json|package\.json|lint|test|verify|workflow|config|script'; then
    report_issue "Allowed Supporting Files must proactively name realistic support file families"
    issue_count=$((issue_count + 1))
  fi

  invariants_body="$(section_body "Preserved Invariants" "$file")"
  invariant_bullets="$(printf '%s\n' "$invariants_body" | awk '/^- / {count += 1} END {print count + 0}')"
  if [ "$invariant_bullets" -lt 2 ]; then
    report_issue "Preserved Invariants should list at least 2 explicit bullets"
    issue_count=$((issue_count + 1))
  fi
  if has_rg; then
    if ! printf '%s\n' "$invariants_body" | rg -qi 'remain|preserve|unchanged|mandatory|canonical|intact|stable'; then
      report_issue "Preserved Invariants must name behaviors or rules that cannot drift"
      issue_count=$((issue_count + 1))
    fi
  elif ! printf '%s\n' "$invariants_body" | grep -Eqi 'remain|preserve|unchanged|mandatory|canonical|intact|stable'; then
    report_issue "Preserved Invariants must name behaviors or rules that cannot drift"
    issue_count=$((issue_count + 1))
  fi

  if has_rg; then
    if rg -qi 'where appropriate|as needed|if helpful|if applicable' "$file"; then
      report_issue "Spec still contains vague guidance phrases that often cause loop churn"
      issue_count=$((issue_count + 1))
    fi
  elif grep -Eqi 'where appropriate|as needed|if helpful|if applicable' "$file"; then
    report_issue "Spec still contains vague guidance phrases that often cause loop churn"
    issue_count=$((issue_count + 1))
  fi

  checkpoint_bullets="$(printf '%s\n' "$(section_body "Refinement Checkpoints" "$file")" | awk '/^- / {count += 1} END {print count + 0}')"
  if [ "$checkpoint_bullets" -lt 1 ]; then
    report_issue "Refinement Checkpoints must contain at least one concrete checkpoint bullet"
    issue_count=$((issue_count + 1))
  fi

  if has_rg; then
    if rg -qi '^- Must .*(appropriate|as needed|if helpful|if applicable|and/or|etc\.)' "$file"; then
      report_issue "Acceptance criteria still contain vague execution language"
      issue_count=$((issue_count + 1))
    fi
  elif grep -Eqi '^- Must .*(appropriate|as needed|if helpful|if applicable|and/or|etc\.)' "$file"; then
    report_issue "Acceptance criteria still contain vague execution language"
    issue_count=$((issue_count + 1))
  fi

  if [ "$issue_count" -gt 0 ]; then
    exit 1
  fi

  printf 'PASS: %s is loop-ready\n' "${file#$WORKSPACE_ROOT/}"
}

main "$@"
