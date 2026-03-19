#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMPDIR_MATRIX=""

run_case() {
  local tmpdir="$1"
  local name="$2"
  local feature_text="$3"
  local constraints_text="$4"
  local expected_recommend="$5"

  local prompt_file stderr_file stdout_file compact_prompt_file compact_stderr_file compact_stdout_file
  prompt_file="$tmpdir/${name}.prompt.txt"
  stderr_file="$tmpdir/${name}.stderr.log"
  stdout_file="$tmpdir/${name}.stdout.log"
  compact_prompt_file="$tmpdir/${name}.compact.prompt.txt"
  compact_stderr_file="$tmpdir/${name}.compact.stderr.log"
  compact_stdout_file="$tmpdir/${name}.compact.stdout.log"

  rm -f \
    "$prompt_file" "$stderr_file" "$stdout_file" \
    "$compact_prompt_file" "$compact_stderr_file" "$compact_stdout_file" \
    "$tmpdir/scripts/ralph/prd.json" \
    "$tmpdir/scripts/ralph/tasks/prds/"*.md

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

  local recommend="no"
  local default_compact_prompt="no"
  local compact_prompt="no"

  if rg -q "compact mode recommended" "$stderr_file"; then
    recommend="yes"
  fi
  if rg -q "compact Ralph planning package" "$prompt_file"; then
    default_compact_prompt="yes"
  fi

  # Safety check: recommendation-only mode must not switch prompts automatically.
  [ "$default_compact_prompt" = "no" ] || {
    echo "[matrix] FAIL: $name auto-switched to compact prompt without --compact" >&2
    exit 1
  }

  (
    cd "$tmpdir"
    CODEX_PROMPT_PATH="$compact_prompt_file" \
    CODEX_BIN=./fake-codex \
      bash scripts/ralph/ralph-prd.sh \
        --compact \
        --feature "$feature_text" \
        --constraints "$constraints_text" \
        --no-questions \
        >"$compact_stdout_file" 2>"$compact_stderr_file"
  )

  if rg -q "compact Ralph planning package" "$compact_prompt_file"; then
    compact_prompt="yes"
  fi
  [ "$compact_prompt" = "yes" ] || {
    echo "[matrix] FAIL: $name did not use compact prompt when explicitly requested" >&2
    exit 1
  }

  local verdict="match"
  if [ "$recommend" != "$expected_recommend" ]; then
    verdict="mismatch"
  fi

  printf "%s\texpected=%s\trecommend=%s\tdefault_prompt=%s\texplicit_compact=%s\tverdict=%s\n" \
    "$name" "$expected_recommend" "$recommend" "$default_compact_prompt" "$compact_prompt" "$verdict"
}

main() {
  local tmpdir
  tmpdir="$(mktemp -d /tmp/ralph-prd-matrix-XXXXXX)"
  TMPDIR_MATRIX="$tmpdir"
  trap 'rm -rf "${TMPDIR_MATRIX:-}"' EXIT

  mkdir -p "$tmpdir/scripts/ralph/tasks/prds" "$tmpdir/scripts/ralph/lib" "$tmpdir/scripts/ralph/templates"
  (
    cd "$tmpdir"
    git init -b main >/dev/null
    git config user.name "Ralph Matrix Test"
    git config user.email "ralph-matrix@example.com"
  )

  cp "$REPO_ROOT/ralph-prd.sh" "$tmpdir/scripts/ralph/ralph-prd.sh"
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
cat > "$prompt_path"
mkdir -p scripts/ralph/tasks/prds
cat > scripts/ralph/tasks/prds/prd-test.md <<'PRD'
# Test PRD
PRD
cat > scripts/ralph/prd.json <<'JSON'
{"project":"x","branchName":"ralph/test","description":"d","userStories":[{"id":"US-001","title":"t","description":"d","acceptanceCriteria":["Typecheck passes","Lint passes","Unit tests pass"],"priority":1,"passes":false,"notes":""}]}
JSON
EOF
  chmod +x "$tmpdir/fake-codex"

  local results
  results="$(
    {
      run_case "$tmpdir" "tiny_two_file_console" \
        "Change greeting text" \
        "Keep changes limited to src/index.ts and tests/hello.test.mjs only." \
        "yes"
      run_case "$tmpdir" "tiny_one_file_copy" \
        "Update copy in src/banner.ts" \
        "Only change src/banner.ts." \
        "yes"
      run_case "$tmpdir" "ui_small_two_file" \
        "Update button label" \
        "Keep changes limited to src/app.ts and tests/app.test.mjs only. Verify browser output." \
        "yes"
      run_case "$tmpdir" "api_copy_small" \
        "Adjust API response copy" \
        "Keep changes limited to src/api/messages.ts and tests/messages.test.ts." \
        "yes"
      run_case "$tmpdir" "router_fix_cross_cutting" \
        "Fix redirect loop" \
        "Keep changes limited to app/router.ts and tests/router.test.ts." \
        "no"
      run_case "$tmpdir" "auth_cross_cutting" \
        "Refactor auth session handling across shared providers" \
        "Update auth/session flow, shared provider wiring, and routing guards." \
        "no"
      run_case "$tmpdir" "db_migration" \
        "Add user preference persistence" \
        "Update schema, migration, and API contract." \
        "no"
      run_case "$tmpdir" "broad_refactor" \
        "Refactor shared state management" \
        "Touch provider wiring, event pipeline, and shared hooks." \
        "no"
    }
  )"

  printf '%s\n' "$results"

  local total matches mismatches
  total="$(printf '%s\n' "$results" | sed '/^$/d' | wc -l | tr -d ' ')"
  matches="$(printf '%s\n' "$results" | awk -F '\t' '$6=="verdict=match"{count+=1} END{print count+0}')"
  mismatches="$(printf '%s\n' "$results" | awk -F '\t' '$6=="verdict=mismatch"{count+=1} END{print count+0}')"

  echo "[matrix] summary: total=$total matches=$matches mismatches=$mismatches"
  [ "$mismatches" -eq 0 ] || {
    echo "[matrix] FAIL: recommendation heuristics mismatched expected outcomes" >&2
    exit 1
  }

  echo "[matrix] PASS: compact recommendation matrix"
}

main "$@"
