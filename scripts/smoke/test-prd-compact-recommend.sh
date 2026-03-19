#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

run_case() {
  local case_name="$1"
  local feature_text="$2"
  local constraints_text="$3"
  local expect_recommend="$4"
  local expect_compact_prompt="$5"
  local tmpdir prompt_file stderr_file stdout_file

  tmpdir="$(mktemp -d "/tmp/ralph-prd-rec-${case_name}-XXXXXX")"
  prompt_file="$tmpdir/codex-prompt.txt"
  stderr_file="$tmpdir/stderr.log"
  stdout_file="$tmpdir/stdout.log"

  mkdir -p "$tmpdir/scripts/ralph/tasks/prds" "$tmpdir/scripts/ralph/lib" "$tmpdir/scripts/ralph/templates"
  (
    cd "$tmpdir"
    git init -b main >/dev/null
    git config user.name "Ralph Compact Test"
    git config user.email "ralph-compact@example.com"

    cp "$REPO_ROOT/ralph-prd.sh" scripts/ralph/ralph-prd.sh
    cp "$REPO_ROOT/lib/editor-intake.sh" scripts/ralph/lib/editor-intake.sh
    cp "$REPO_ROOT/templates/prd-intake.md" scripts/ralph/templates/prd-intake.md

    cat > fake-codex <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "--yolo" ] && [ "\${2:-}" = "exec" ] && [ "\${3:-}" = "--help" ]; then
  echo 'Run Codex non-interactively'
  exit 0
fi
cat > "$prompt_file"
mkdir -p scripts/ralph/tasks/prds
cat > scripts/ralph/tasks/prds/prd-test.md <<'PRD'
# Test PRD
PRD
cat > scripts/ralph/prd.json <<'JSON'
{"project":"x","branchName":"ralph/test","description":"d","userStories":[{"id":"US-001","title":"t","description":"d","acceptanceCriteria":["Typecheck passes","Lint passes","Unit tests pass"],"priority":1,"passes":false,"notes":""}]}
JSON
EOF
    chmod +x fake-codex

    CODEX_BIN=./fake-codex bash scripts/ralph/ralph-prd.sh \
      --feature "$feature_text" \
      --constraints "$constraints_text" \
      --no-questions \
      >"$stdout_file" 2>"$stderr_file"
  )

  if [ "$expect_recommend" = "yes" ]; then
    grep -q "compact mode recommended" "$stderr_file"
  else
    ! grep -q "compact mode recommended" "$stderr_file"
  fi

  if [ "$expect_compact_prompt" = "yes" ]; then
    grep -q "compact Ralph planning package" "$prompt_file"
  else
    ! grep -q "compact Ralph planning package" "$prompt_file"
  fi

  rm -rf "$tmpdir"
}

run_case \
  "hit" \
  "Change greeting text" \
  "Keep changes limited to src/index.ts and tests/hello.test.mjs only." \
  "yes" \
  "no"

run_case \
  "miss" \
  "Refactor auth session handling across shared providers" \
  "Update auth/session flow, shared provider wiring, and routing guards." \
  "no" \
  "no"

echo "[smoke] PASS: compact recommendation heuristics"
