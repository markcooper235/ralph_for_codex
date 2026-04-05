#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMPDIR_UI_SCOPE=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  grep -qE "$pattern" "$file" || fail "Expected pattern '$pattern' in $file"
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  if grep -qE "$pattern" "$file"; then
    fail "Did not expect pattern '$pattern' in $file"
  fi
}

run_case() {
  local tmpdir="$1"
  local name="$2"
  local feature_text="$3"
  local constraints_text="$4"
  local expect_hint="$5"

  local prompt_file stdout_file stderr_file
  prompt_file="$tmpdir/${name}.prompt.txt"
  stdout_file="$tmpdir/${name}.stdout.log"
  stderr_file="$tmpdir/${name}.stderr.log"

  rm -f "$prompt_file" "$stdout_file" "$stderr_file" "$tmpdir/scripts/ralph/prd.json" "$tmpdir/scripts/ralph/tasks/prds/"*.md

  (
    cd "$tmpdir"
    CODEX_PROMPT_PATH="$prompt_file" \
    CODEX_BIN=./fake-codex \
      bash scripts/ralph/ralph-prd.sh \
        --feature "$feature_text" \
        --constraints "$constraints_text" \
        --no-questions \
        >"$stdout_file" 2>"$stderr_file"
  )

  if [ "$expect_hint" = "yes" ]; then
    assert_contains "$prompt_file" "Additional guidance for this request:"
    assert_contains "$prompt_file" "keep them in one story"
  else
    assert_not_contains "$prompt_file" "Additional guidance for this request:"
  fi
}

main() {
  local tmpdir
  tmpdir="$(mktemp -d /tmp/ralph-prd-ui-scope-XXXXXX)"
  TMPDIR_UI_SCOPE="$tmpdir"
  trap 'rm -rf "${TMPDIR_UI_SCOPE:-}"' EXIT

  mkdir -p "$tmpdir/scripts/ralph/tasks/prds" "$tmpdir/scripts/ralph/lib" "$tmpdir/scripts/ralph/templates"
  (
    cd "$tmpdir"
    git init -b main >/dev/null
    git config user.name "Ralph UI Scope Test"
    git config user.email "ralph-ui-scope@example.com"
  )

  cp "$REPO_ROOT/ralph-prd.sh" "$tmpdir/scripts/ralph/ralph-prd.sh"
  cp "$REPO_ROOT/ralph-spec-check.sh" "$tmpdir/scripts/ralph/ralph-spec-check.sh"
  cp "$REPO_ROOT/ralph-spec-strengthen.sh" "$tmpdir/scripts/ralph/ralph-spec-strengthen.sh"
  cp "$REPO_ROOT/lib/editor-intake.sh" "$tmpdir/scripts/ralph/lib/editor-intake.sh"
  cp "$REPO_ROOT/templates/prd-intake.md" "$tmpdir/scripts/ralph/templates/prd-intake.md"

  cat > "$tmpdir/fake-codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--yolo" ] && [ "${2:-}" = "exec" ] && [ "${3:-}" = "--help" ]; then
  echo 'Run Codex non-interactively'
  exit 0
fi
prompt_path="${CODEX_PROMPT_PATH:-codex-prompt.txt}"
if [ -f "$prompt_path" ]; then
  printf '\n==== NEXT PROMPT ====\n' >> "$prompt_path"
fi
cat >> "$prompt_path"
mkdir -p scripts/ralph/tasks/prds
cat > scripts/ralph/tasks/prds/prd-test.md <<'PRD'
# Test PRD

## Scope
- Keep the UI copy change scoped to the named source and proof files.

## Out of Scope
- Router refactors or unrelated workflow changes.

## Execution Model
- Start with the first slice in the exact source file path, keep support scope bounded, and verify before widening.
- Keep verification pressure explicit through typecheck, lint, tests, and any required browser proof.

## First Slice Expectations
- exact source: src/example.ts
- destination: scripts/ralph/prd.json
- entrypoint: ./scripts/ralph/ralph-prd.sh
- commands: npm run typecheck, npm run lint, npm test

## Allowed Supporting Files
- package.json
- tests/example.test.ts
- scripts/verify-example.sh

## Preserved Invariants
- Existing Ralph planning contracts remain stable and unchanged.
- Verification expectations remain intact and canonical.

## User Stories
### Story 1: Test story
Acceptance Criteria
- Must update the exact source slice with execution-ready detail.
- Must preserve the required support-file workflow and verification commands.
- Must ensure Typecheck passes.
- Must ensure Lint passes.
- Must ensure Unit tests pass.

## Refinement Checkpoints
- Confirm the first slice stays inside the named scope.

## Definition of Done
- The PRD is loop-ready and verification remains intact.
PRD
cat > scripts/ralph/prd.json <<'JSON'
{"project":"x","branchName":"ralph/test","description":"d","userStories":[{"id":"US-001","title":"t","description":"d","acceptanceCriteria":["Typecheck passes","Lint passes","Unit tests pass"],"priority":1,"passes":false,"notes":""}]}
JSON
EOF
  chmod +x "$tmpdir/fake-codex"

  run_case "$tmpdir" \
    "ui_small_two_file" \
    "Change UI output greeting to Hello PRD Ralph in src/index.ts and verify rendered #app output." \
    "Keep changes limited to src/index.ts and tests/hello.test.mjs only. Verify browser output." \
    "yes"

  run_case "$tmpdir" \
    "router_cross_cutting" \
    "Fix browser redirect loop" \
    "Keep changes limited to app/router.ts and tests/router.test.ts only. Verify browser output." \
    "no"

  echo "[ui-scope] PASS: full-mode UI single-slice prompt guidance"
}

main "$@"
