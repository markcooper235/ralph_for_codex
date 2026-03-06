#!/bin/bash
# Optional OpenSpec adapter for Ralph.
# This script is intentionally separate from scripts/ralph/* runtime flow.

set -euo pipefail

WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
OPENSPEC_DIR="$WORKSPACE_ROOT/openspec"
DEFAULT_OUT="$WORKSPACE_ROOT/scripts/ralph/prd.json"
CODEX_BIN="${CODEX_BIN:-codex}"

usage() {
  cat <<'EOF'
OpenSpec adapter for Ralph (optional path).

Usage:
  ./scripts/openspec/openspec-skill.sh init
  ./scripts/openspec/openspec-skill.sh list
  ./scripts/openspec/openspec-skill.sh change <name>
  ./scripts/openspec/openspec-skill.sh convert --change <name> [--out PATH] [--project NAME] [--branch BRANCH]

Commands:
  init                 Initialize OpenSpec in the current repo if needed.
  list                 List OpenSpec changes.
  change <name>        Create a new OpenSpec change and show status.
  convert              Convert OpenSpec change artifacts into Ralph prd.json.

Options (convert):
  --change NAME        OpenSpec change name under openspec/changes/<name> (required).
  --out PATH           Output path (default: scripts/ralph/prd.json).
  --project NAME       Override project name in output JSON.
  --branch BRANCH      Override branchName in output JSON.
  -h, --help           Show this help.

Notes:
  - This is an alternative planning path. It does not alter Ralph loop behavior.
  - Ralph still consumes scripts/ralph/prd.json as usual.
EOF
}

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
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

slugify_branch_segment() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's|[^a-z0-9._-]+|-|g' \
    | sed -E 's|^-+||; s|-+$||'
}

to_rel_path() {
  local path="$1"
  if [[ "$path" == "$WORKSPACE_ROOT/"* ]]; then
    printf '%s\n' "${path#$WORKSPACE_ROOT/}"
  else
    printf '%s\n' "$path"
  fi
}

ensure_openspec_ready() {
  require_cmd openspec
  if [ ! -d "$OPENSPEC_DIR" ]; then
    fail "OpenSpec is not initialized in this repo. Run: ./scripts/openspec/openspec-skill.sh init"
  fi
}

cmd_init() {
  require_cmd openspec
  if openspec status --json >/dev/null 2>&1; then
    echo "OpenSpec already initialized."
    return 0
  fi
  echo "Initializing OpenSpec..."
  openspec init
}

cmd_list() {
  ensure_openspec_ready
  openspec list --json || openspec list
}

cmd_change() {
  local change_name="${1:-}"
  [ -n "$change_name" ] || fail "Usage: change <name>"
  ensure_openspec_ready
  openspec new change "$change_name"
  openspec status --change "$change_name"
}

cmd_convert() {
  local change_name=""
  local out_path="$DEFAULT_OUT"
  local project_name=""
  local branch_name=""
  local change_dir tasks_path proposal_path design_path specs_dir
  local specs_count artifacts_list
  local prompt codex_args=()
  local out_dir out_rel project_guess branch_guess

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --change)
        change_name="${2:-}"; shift 2 ;;
      --out)
        out_path="${2:-}"; shift 2 ;;
      --project)
        project_name="${2:-}"; shift 2 ;;
      --branch)
        branch_name="${2:-}"; shift 2 ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown convert argument: $1"
        ;;
    esac
  done

  [ -n "$change_name" ] || fail "convert requires --change <name>"

  require_cmd jq
  require_cmd sed
  require_cmd tr
  require_cmd find
  require_cmd "$CODEX_BIN"
  ensure_openspec_ready

  change_dir="$OPENSPEC_DIR/changes/$change_name"
  [ -d "$change_dir" ] || fail "OpenSpec change not found: $change_dir"

  tasks_path="$change_dir/tasks.md"
  proposal_path="$change_dir/proposal.md"
  design_path="$change_dir/design.md"
  specs_dir="$change_dir/specs"

  [ -f "$tasks_path" ] || fail "Missing required OpenSpec tasks file: $tasks_path"

  specs_count=0
  if [ -d "$specs_dir" ]; then
    specs_count="$(find "$specs_dir" -type f -name '*.md' | wc -l | tr -d '[:space:]')"
  fi

  project_guess="$(basename "$WORKSPACE_ROOT")"
  [ -n "$project_name" ] || project_name="$project_guess"
  branch_guess="ralph/$(slugify_branch_segment "$change_name")"
  [ -n "$branch_name" ] || branch_name="$branch_guess"

  out_dir="$(dirname "$out_path")"
  mkdir -p "$out_dir"
  out_rel="$(to_rel_path "$out_path")"

  artifacts_list="- required: $(to_rel_path "$tasks_path")"
  [ -f "$proposal_path" ] && artifacts_list="$artifacts_list"$'\n'"- optional: $(to_rel_path "$proposal_path")"
  [ -f "$design_path" ] && artifacts_list="$artifacts_list"$'\n'"- optional: $(to_rel_path "$design_path")"
  if [ "$specs_count" -gt 0 ]; then
    artifacts_list="$artifacts_list"$'\n'"- optional: $(to_rel_path "$specs_dir")/**/*.md"
  fi

  prompt=$(
    cat <<EOF
Use the \`ralph\` skill.

Convert OpenSpec change \`$change_name\` into Ralph JSON at \`$out_rel\`.

OpenSpec artifacts to read:
$artifacts_list

Requirements:
1. Write valid JSON with keys: project, branchName, description, userStories.
2. Set \`project\` to \`$project_name\`.
3. Set \`branchName\` to \`$branch_name\`.
4. Stories must be small and completable in one Ralph iteration.
5. Order stories by dependency.
6. Every story must include acceptance criteria for typecheck, lint, and tests.
7. For UI stories include browser verification criterion.
8. Set \`passes: false\` for all stories.

Return only a short summary after writing the file.
EOF
  )

  build_codex_exec_args codex_args
  printf '%s\n' "$prompt" | "$CODEX_BIN" "${codex_args[@]}"

  [ -f "$out_path" ] || fail "Expected output file not found: $out_path"

  jq -e '
    (.project | type == "string" and length > 0) and
    (.branchName | type == "string" and length > 0) and
    (.description | type == "string") and
    (.userStories | type == "array" and length > 0)
  ' "$out_path" >/dev/null 2>&1 || fail "Generated JSON missing required fields."

  jq -e '
    all(.userStories[];
      any(.acceptanceCriteria[]; test("(?i)typecheck passes")) and
      any(.acceptanceCriteria[]; test("(?i)lint passes")) and
      (
        any(.acceptanceCriteria[]; test("(?i)unit tests pass")) or
        any(.acceptanceCriteria[]; test("(?i)tests pass"))
      )
    )
  ' "$out_path" >/dev/null 2>&1 || fail "Each story must include typecheck/lint/tests acceptance criteria."

  echo "Converted OpenSpec change '$change_name' to $out_rel"
  echo "Stories: $(jq '.userStories | length' "$out_path")"
  echo "Branch: $(jq -r '.branchName' "$out_path")"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    init)
      shift
      cmd_init "$@"
      ;;
    list)
      shift
      cmd_list "$@"
      ;;
    change)
      shift
      cmd_change "$@"
      ;;
    convert)
      shift
      cmd_convert "$@"
      ;;
    -h|--help|"")
      usage
      ;;
    *)
      fail "Unknown command: $cmd"
      ;;
  esac
}

main "$@"
