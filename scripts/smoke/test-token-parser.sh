#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/token-parser.sh
source "$SCRIPT_DIR/lib/token-parser.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  [ "$actual" = "$expected" ] || fail "$label (expected $expected got $actual)"
}

main() {
  local tmpdir log_file
  tmpdir="$(mktemp -d /tmp/ralph-token-parser-XXXXXX)"
  trap 'rm -rf "${tmpdir:-}"' EXIT

  log_file="$tmpdir/tokens.log"
  cat >"$log_file" <<'EOF'
codex
ok
tokens used
6,574
EOF
  assert_eq "$(extract_tokens_from_log "$log_file")" "6574" "two-line tokens used parsing"

  cat >"$log_file" <<'EOF'
codex
ok
Tokens used: 2,734
EOF
  assert_eq "$(extract_tokens_from_log "$log_file")" "2734" "inline tokens used parsing"

  cat >"$log_file" <<'EOF'
{"total_tokens": 1876}
EOF
  assert_eq "$(extract_tokens_from_log "$log_file")" "1876" "json total_tokens parsing"

  cat >"$log_file" <<'EOF'
tokens used
1200
Ralph Iteration 1 of 10
tokens used
3400
EOF
  assert_eq "$(extract_preloop_tokens_from_log "$log_file")" "1200" "preloop token cutoff"

  echo "[token-parser] PASS: smoke token parser"
}

main "$@"
