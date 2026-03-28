#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$WORKSPACE_ROOT" ]; then
  WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
CODEX_BIN="${CODEX_BIN:-codex}"
SPEC_CHECK="$SCRIPT_DIR/ralph-spec-check.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/ralph-spec-strengthen.sh <prd-markdown-path>

Strengthens an existing PRD markdown file in place until it is more loop-ready.
Returns non-zero when the spec still lacks enough context to strengthen honestly.
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

main() {
  local file rel_path issues prompt codex_args=()

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

  require_cmd "$CODEX_BIN"
  require_cmd "$SPEC_CHECK"

  issues="$("$SPEC_CHECK" "$file" 2>&1 || true)"
  rel_path="${file#$WORKSPACE_ROOT/}"

  prompt=$(
    cat <<EOF
Use the \`prd\` skill.

Strengthen this existing PRD markdown in place so it becomes loop-ready for Ralph:
\`$rel_path\`

Current spec-check findings:
$issues

Requirements:
1. Preserve the epic or feature goal, dependencies, and real constraints already present in the file.
2. Rewrite the markdown in place so it passes Ralph's loop-readiness expectations.
3. Make the spec more execution-ready, not more verbose for its own sake.
4. Be concise and token-efficient. Prefer short bullets, direct language, and the minimum wording needed to remove ambiguity.
5. Do not add narrative background, motivational prose, or repeated reminders unless they materially change execution behavior.
6. Reuse existing sections where possible instead of expanding the document with redundant explanation.
7. Add or strengthen these sections only as much as needed:
   - \`## Execution Model\`
   - \`## First Slice Expectations\`
   - \`## Allowed Supporting Files\`
   - \`## Preserved Invariants\`
8. Keep story count as low as honestly possible while preserving safe sequencing; do not add stories just to spread detail around.
9. Tighten user stories so they name concrete first slices, caller migration sets, support file families, and verification proof obligations.
10. Reduce overlapping ownership with neighboring epics when the file itself provides enough context to do so honestly.
11. If context is strong enough, fix the spec completely and keep assumptions explicit but minimal.
12. If context is not strong enough to strengthen honestly, do not bluff. Leave the file unchanged and output:
   \`Status: blocked\`
   \`Reason: <short reason>\`
13. If you do strengthen the spec, output:
   \`Status: strengthened\`
   \`Reason: <short summary>\`

Do not print the full file or a diff.
EOF
  )

  build_codex_exec_args codex_args
  printf '%s\n' "$prompt" | "$CODEX_BIN" "${codex_args[@]}"

  [ -f "$file" ] || fail "Spec file disappeared during strengthening: $file"
  "$SPEC_CHECK" "$file" >/dev/null || fail "Spec is still weak after strengthening: $file"
}

main "$@"
