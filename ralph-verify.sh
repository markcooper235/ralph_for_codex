#!/usr/bin/env bash
set -euo pipefail

MODE="targeted"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
RALPH_DIR="$WORKSPACE_ROOT/scripts/ralph"
IGNORE_FILE="$RALPH_DIR/known-test-baseline-failures.txt"

usage() {
  cat <<USAGE
Usage: ./scripts/ralph/ralph-verify.sh [--targeted|--full]

Modes:
  --targeted  Run typecheck, lint, and tests focused on changed files (default)
  --full      Run typecheck, lint, then full suite with known baseline failures ignored
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --targeted) MODE="targeted"; shift ;;
    --full) MODE="full"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

cd "$WORKSPACE_ROOT"

run_base_checks() {
  echo "[ralph-verify] running typecheck"
  npm run typecheck
  echo "[ralph-verify] running lint"
  npm run lint
}

collect_changed_files() {
  {
    git diff --name-only --diff-filter=ACMRTUXB HEAD || true
    git ls-files --others --exclude-standard || true
  } | sed '/^$/d' | sort -u
}

discover_targeted_tests() {
  local changed tests
  changed="$(collect_changed_files)"
  [ -n "$changed" ] || return 0

  tests=""

  # Include changed test files directly.
  while IFS= read -r f; do
    case "$f" in
      *test.ts|*test.tsx|*test.js|*test.jsx|*spec.ts|*spec.tsx|*spec.js|*spec.jsx)
        [ -f "$f" ] && tests+="$f"$'\n'
        ;;
    esac
  done <<< "$changed"

  # For changed source files, infer nearby tests by basename in src/app/tests folders.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      src/*|app/*)
        local base
        base="$(basename "$f")"
        base="${base%.*}"
        rg --files src app 2>/dev/null | rg "/__tests__/|\.test\.|\.spec\." | rg "/${base}(\.test|\.spec)\." || true
        ;;
    esac
  done <<< "$changed" >> /tmp/ralph-targeted-tests.$$ || true

  if [ -s /tmp/ralph-targeted-tests.$$ ]; then
    tests+="$(cat /tmp/ralph-targeted-tests.$$)"$'\n'
  fi
  rm -f /tmp/ralph-targeted-tests.$$ || true

  printf '%s' "$tests" | sed '/^$/d' | sort -u
}

build_ignore_regex() {
  [ -f "$IGNORE_FILE" ] || return 0
  awk 'NF && $1 !~ /^#/' "$IGNORE_FILE" | paste -sd'|' -
}

run_targeted_tests() {
  local tests
  tests="$(discover_targeted_tests || true)"
  if [ -z "$tests" ]; then
    echo "[ralph-verify] no targeted test files inferred from changed files; skipping targeted test run"
    return 0
  fi

  echo "[ralph-verify] running targeted tests"
  # shellcheck disable=SC2206
  local args=( $tests )
  npm test -- --runInBand --runTestsByPath "${args[@]}"
}

run_full_suite() {
  local ignore_re
  ignore_re="$(build_ignore_regex || true)"
  echo "[ralph-verify] running full test suite"
  if [ -n "$ignore_re" ]; then
    echo "[ralph-verify] applying known baseline ignore patterns from $IGNORE_FILE"
    npm test -- --runInBand --testPathIgnorePatterns "$ignore_re"
  else
    npm test -- --runInBand
  fi
}

run_base_checks
case "$MODE" in
  targeted) run_targeted_tests ;;
  full) run_full_suite ;;
  *) echo "Invalid mode: $MODE" >&2; exit 1 ;;
esac

echo "[ralph-verify] $MODE verification passed"
