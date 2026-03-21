#!/bin/bash
# PRD bootstrap wrapper for Ralph.
# Editor-first intake for concept + constraints + planning context, then
# run Codex with PRD and Ralph skills.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CODEX_BIN="${CODEX_BIN:-codex}"
PRD_JSON="${PRD_JSON_PATH:-$SCRIPT_DIR/prd.json}"
ACTIVE_PRD_FILE="$SCRIPT_DIR/.active-prd"
EDITOR_HELPER="$SCRIPT_DIR/lib/editor-intake.sh"

# shellcheck source=./lib/editor-intake.sh
source "$EDITOR_HELPER"

QUIET=0
FEATURE_CONCEPT=""
HARD_CONSTRAINTS=""
ACTIVATE_CURRENT_ONLY=0
COMPACT_MODE=0

# Quick question modes: ask (prompt user), on (force), off (skip)
QUICK_QUESTIONS_MODE="ask"
REMOVE_TARGET=""
REMOVE_HARD=0
ASSUME_YES=0

PRIMARY_GOAL="Not provided"
TARGET_USERS="Not provided"
SCOPE_LEVEL="Not provided"
AUTO_COMPACT_SELECTED=0
UI_SINGLE_SLICE_HINT=0

usage() {
  cat <<'USAGE'
Usage: ./ralph-prd.sh [options]

Generate PRD markdown + prd.json via Codex skills.

Options:
  --feature TEXT           Feature concept (skip editor for this field)
  --constraints TEXT       Hard constraints/dependencies (skip editor for this field)
  --activate-current       Mark the current prd.json as active standalone PRD and exit
  --compact                Use a lighter-weight planning prompt for tightly scoped work
  --remove PATH            Remove/archive an existing PRD markdown file
  --hard                   With --remove: permanently delete instead of archive
  --yes                    With --remove: skip confirmation prompt
  --quick-questions        Force the 3-question clarifier intake
  --no-questions           Skip clarifier intake (sets defaults)
  --quiet                  Reduce wrapper output (Codex output still shown)
  -h, --help               Show help

Environment:
  CODEX_BIN                Codex CLI command (default: codex)
  PRD_JSON_PATH            Output path for prd.json (default: <script-dir>/prd.json)
  RALPH_EDITOR             Editor command for intake (fallback: VISUAL, EDITOR, nano, vi)
  RALPH_PRD_COMPACT        Set to 1/true to default to --compact mode
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

count_distinct_file_paths() {
  printf '%s\n%s\n' "$FEATURE_CONCEPT" "$HARD_CONSTRAINTS" \
    | grep -Eo '([A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+\.[A-Za-z0-9]+' \
    | sort -u \
    | wc -l \
    | tr -d ' '
}

should_auto_compact_mode() {
  local combined lower explicit_scope path_count feature_len
  combined="$(printf '%s\n%s\n' "$FEATURE_CONCEPT" "$HARD_CONSTRAINTS")"
  lower="$(printf '%s' "$combined" | tr '[:upper:]' '[:lower:]')"
  feature_len="$(printf '%s' "$FEATURE_CONCEPT" | wc -c | tr -d ' ')"
  path_count="$(count_distinct_file_paths)"

  case "$lower" in
    *auth*|*session*|*database*|*migration*|*schema*|*routing*|*router*|*provider*|*permission*|*"api contract"*|*"shared state"*|*"event pipeline"*|*"global config"*|*refactor*|*architecture*|*epic*|*sprint*|*cross-cutting*|*shared\ hook*|*shared\ component*|*state\ management*|*browser*|*playwright*|*cypress*)
      return 1
      ;;
  esac

  explicit_scope=0
  case "$lower" in
    *"keep changes limited to "*|*"only change "*|*"limited to "*)
      explicit_scope=1
      ;;
  esac

  [ "$explicit_scope" -eq 1 ] || return 1
  [ "$path_count" -ge 1 ] && [ "$path_count" -le 2 ] || return 1
  [ "$feature_len" -le 120 ] || return 1
  return 0
}

should_hint_single_slice_ui_story() {
  local combined lower explicit_scope path_count feature_len
  combined="$(printf '%s\n%s\n' "$FEATURE_CONCEPT" "$HARD_CONSTRAINTS")"
  lower="$(printf '%s' "$combined" | tr '[:upper:]' '[:lower:]')"
  feature_len="$(printf '%s' "$FEATURE_CONCEPT" | wc -c | tr -d ' ')"
  path_count="$(count_distinct_file_paths)"

  case "$lower" in
    *browser*|*ui*|*"#app"*|*render*)
      ;;
    *)
      return 1
      ;;
  esac

  case "$lower" in
    *auth*|*session*|*database*|*migration*|*schema*|*routing*|*router*|*provider*|*permission*|*"api contract"*|*"shared state"*|*"event pipeline"*|*"global config"*|*refactor*|*architecture*|*epic*|*sprint*|*cross-cutting*|*shared\ hook*|*shared\ component*|*state\ management*|*playwright*|*cypress*)
      return 1
      ;;
  esac

  explicit_scope=0
  case "$lower" in
    *"keep changes limited to "*|*"only change "*|*"limited to "*)
      explicit_scope=1
      ;;
  esac

  [ "$explicit_scope" -eq 1 ] || return 1
  [ "$path_count" -ge 1 ] && [ "$path_count" -le 2 ] || return 1
  [ "$feature_len" -le 200 ] || return 1
  return 0
}

mark_active_standalone_prd() {
  local source_path="${1:-scripts/ralph/prd.json}"
  local base_branch
  base_branch="$(git branch --show-current 2>/dev/null || true)"
  if [ -z "$base_branch" ]; then
    if git show-ref --verify --quiet refs/heads/master; then
      base_branch="master"
    elif git show-ref --verify --quiet refs/heads/main; then
      base_branch="main"
    else
      base_branch="main"
    fi
  fi
  cat >"$ACTIVE_PRD_FILE" <<JSON
{
  "mode": "standalone",
  "baseBranch": "$base_branch",
  "sourcePath": "$source_path",
  "activatedAt": "$(date -Iseconds)"
}
JSON
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

commit_generated_prd_markdown_if_needed() {
  local rel_path="$1"
  local abs_path status_line

  [ -n "$rel_path" ] || return 0
  abs_path="$WORKSPACE_ROOT/$rel_path"
  [ -f "$abs_path" ] || return 0

  status_line="$(git status --porcelain -- "$abs_path" || true)"
  [ -n "$status_line" ] || return 0

  git add -- "$abs_path"
  if git diff --cached --quiet; then
    return 0
  fi

  git commit -m "chore(ralph): add standalone PRD spec" >/dev/null
  log "Committed standalone PRD spec: $rel_path"
}

snapshot_prd_markdown_state() {
  mkdir -p "$SCRIPT_DIR/tasks/prds"
  find "$SCRIPT_DIR/tasks/prds" -maxdepth 1 -type f -name 'prd-*.md' -printf '%P|%s|%T@\n' 2>/dev/null | sort
}

detect_changed_prd_markdown() {
  local before_file="$1"
  local after_file="$2"
  local changed_path=""

  changed_path="$(
    awk -F'|' '
      NR==FNR { before[$1]=$0; next }
      {
        if (!($1 in before) || before[$1] != $0) {
          print $1
        }
      }
    ' "$before_file" "$after_file" | tail -n 1
  )"

  if [ -n "$changed_path" ]; then
    printf 'scripts/ralph/tasks/prds/%s\n' "$changed_path"
    return 0
  fi
  return 1
}

latest_prd_markdown() {
  local latest=""
  latest="$(
    find "$SCRIPT_DIR/tasks/prds" -maxdepth 1 -type f -name 'prd-*.md' -printf '%P|%T@\n' 2>/dev/null \
      | sort -t'|' -k2,2n \
      | tail -n 1 \
      | cut -d'|' -f1
  )"
  if [ -n "$latest" ]; then
    printf 'scripts/ralph/tasks/prds/%s\n' "$latest"
    return 0
  fi
  return 1
}

confirm_action() {
  local prompt="$1"
  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    fail "Confirmation required in non-interactive mode. Re-run with --yes."
  fi
  local reply
  read -r -p "$prompt [y/N]: " reply
  case "${reply,,}" in
    y|yes) return 0 ;;
    *) fail "Aborted." ;;
  esac
}

to_workspace_rel_path() {
  local p="$1"
  if [[ "$p" == "$WORKSPACE_ROOT/"* ]]; then
    printf '%s\n' "${p#$WORKSPACE_ROOT/}"
  else
    printf '%s\n' "$p"
  fi
}

resolve_prd_target() {
  local target="$1"
  local active_sprint=""
  local candidate

  if [ -f "$target" ]; then
    if [[ "$target" == "$WORKSPACE_ROOT/"* ]]; then
      printf '%s\n' "${target#$WORKSPACE_ROOT/}"
    else
      printf '%s\n' "$target"
    fi
    return 0
  fi
  if [ -f "$WORKSPACE_ROOT/$target" ]; then
    printf '%s\n' "$target"
    return 0
  fi

  if [ -f "$SCRIPT_DIR/tasks/prds/$target" ]; then
    printf 'scripts/ralph/tasks/prds/%s\n' "$target"
    return 0
  fi
  if [ -f "$SCRIPT_DIR/tasks/prds/prd-$target.md" ]; then
    printf 'scripts/ralph/tasks/prds/prd-%s.md\n' "$target"
    return 0
  fi

  if [ -f "$SCRIPT_DIR/.active-sprint" ]; then
    active_sprint="$(awk 'NF {print; exit}' "$SCRIPT_DIR/.active-sprint" 2>/dev/null || true)"
  fi
  if [ -n "$active_sprint" ]; then
    candidate="scripts/ralph/tasks/$active_sprint/$target"
    if [ -f "$WORKSPACE_ROOT/$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    candidate="scripts/ralph/tasks/$active_sprint/prd-$target.md"
    if [ -f "$WORKSPACE_ROOT/$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  return 1
}

unlink_prd_from_all_epics() {
  local rel_path="$1"
  local epics_file tmp_file
  while IFS= read -r epics_file; do
    [ -f "$epics_file" ] || continue
    tmp_file="$(mktemp)"
    jq --arg p "$rel_path" '
      .epics = (
        .epics
        | map(
            .prdPaths = (
              (.prdPaths // [])
              | map(select(. != $p))
            )
          )
      )
    ' "$epics_file" > "$tmp_file"
    mv "$tmp_file" "$epics_file"
  done < <(find "$SCRIPT_DIR/sprints" -mindepth 2 -maxdepth 2 -type f -name epics.json | sort)
}

remove_prd() {
  local rel_path abs_path slug archive_dir

  rel_path="$(resolve_prd_target "$REMOVE_TARGET" || true)"
  [ -n "$rel_path" ] || fail "Could not resolve PRD target: $REMOVE_TARGET"
  abs_path="$WORKSPACE_ROOT/$rel_path"
  [ -f "$abs_path" ] || fail "PRD file not found: $rel_path"

  slug="$(basename "$rel_path" .md)"
  if [ "$REMOVE_HARD" -eq 1 ]; then
    confirm_action "Permanently delete PRD $rel_path?"
  else
    confirm_action "Archive and remove PRD $rel_path?"
  fi

  unlink_prd_from_all_epics "$rel_path"

  if [ "$REMOVE_HARD" -eq 1 ]; then
    rm -f "$abs_path"
    echo "Permanently removed PRD: $rel_path"
  else
    archive_dir="$SCRIPT_DIR/tasks/archive/prds/$(date +%F)-${slug}-removed"
    if [ -e "$archive_dir" ]; then
      archive_dir="${archive_dir}-$(date +%H%M%S)"
    fi
    mkdir -p "$archive_dir"
    mv "$abs_path" "$archive_dir/"
    cat > "$archive_dir/archive-manifest.txt" <<EOF
action=remove-prd
removed_at=$(date -Iseconds)
source_path=$rel_path
EOF
    echo "Archived PRD to: $archive_dir"
  fi

  if [ -f "$ACTIVE_PRD_FILE" ]; then
    if jq -e --arg p "$rel_path" '.sourcePath == $p' "$ACTIVE_PRD_FILE" >/dev/null 2>&1; then
      rm -f "$ACTIVE_PRD_FILE"
      echo "Cleared active PRD marker: $ACTIVE_PRD_FILE"
    fi
  fi
}

render_prd_context() {
  local active_sprint=""
  local active_epic=""
  local epics_file=""
  local sprint_file="$SCRIPT_DIR/.active-sprint"

  if [ -f "$sprint_file" ]; then
    active_sprint="$(awk 'NF {print; exit}' "$sprint_file" 2>/dev/null || true)"
  fi
  if [ -n "$active_sprint" ]; then
    epics_file="$SCRIPT_DIR/sprints/$active_sprint/epics.json"
    if [ -f "$epics_file" ]; then
      active_epic="$(jq -r '.activeEpicId // ""' "$epics_file" 2>/dev/null || true)"
    fi
  fi

  printf 'Workspace: %s\n' "$(basename "$WORKSPACE_ROOT")"
  printf 'Active sprint: %s\n' "${active_sprint:-none}"
  printf 'Active epic: %s\n' "${active_epic:-none}"
  if [ -n "$epics_file" ] && [ -f "$epics_file" ]; then
    printf 'Current epics (%s):\n' "$epics_file"
    jq -r '.epics | sort_by(.priority, .id) | if length == 0 then "  (none)" else .[] | "  - \(.id) [p=\(.priority)] \(.title)" end' "$epics_file"
  fi
}

collect_prd_intake_via_editor() {
  local context template_path intake_file intake_block

  template_path="$SCRIPT_DIR/templates/prd-intake.md"
  [ -f "$template_path" ] || fail "Missing template: $template_path"

  intake_file="$(mktemp)"
  {
    cat "$template_path"
    echo
    echo "# Current Context"
    render_prd_context
    echo
    echo "# Notes"
    echo "- FEATURE_CONCEPT and HARD_CONSTRAINTS can be multi-line."
    echo "- Keep PRIMARY_GOAL/TARGET_USERS/SCOPE_LEVEL as single-line summaries."
  } > "$intake_file"

  if [ -n "$FEATURE_CONCEPT" ]; then
    awk -v v="$FEATURE_CONCEPT" '
      /^FEATURE_CONCEPT:$/ {print; print v; skip=1; next}
      /^HARD_CONSTRAINTS:$/ {skip=0}
      !skip {print}
    ' "$intake_file" > "$intake_file.tmp" && mv "$intake_file.tmp" "$intake_file"
  fi
  if [ -n "$HARD_CONSTRAINTS" ]; then
    awk -v v="$HARD_CONSTRAINTS" '
      /^HARD_CONSTRAINTS:$/ {print; print v; skip=1; next}
      /^<!-- END INPUT -->$/ {skip=0}
      !skip {print}
    ' "$intake_file" > "$intake_file.tmp" && mv "$intake_file.tmp" "$intake_file"
  fi

  run_editor_on_file "$intake_file"
  intake_block="$(extract_marked_block "$intake_file" "<!-- BEGIN INPUT -->" "<!-- END INPUT -->")"
  rm -f "$intake_file"

  PRIMARY_GOAL="$(printf '%s\n' "$intake_block" | kv_from_block "PRIMARY_GOAL" | trim_whitespace)"
  TARGET_USERS="$(printf '%s\n' "$intake_block" | kv_from_block "TARGET_USERS" | trim_whitespace)"
  SCOPE_LEVEL="$(printf '%s\n' "$intake_block" | kv_from_block "SCOPE_LEVEL" | trim_whitespace)"

  FEATURE_CONCEPT="$({
    printf '%s\n' "$intake_block" | awk '
      /^FEATURE_CONCEPT:[[:space:]]*$/ {in_section=1; next}
      /^HARD_CONSTRAINTS:[[:space:]]*$/ {in_section=0}
      in_section {print}
    '
  })"

  HARD_CONSTRAINTS="$({
    printf '%s\n' "$intake_block" | awk '
      /^HARD_CONSTRAINTS:[[:space:]]*$/ {in_section=1; next}
      in_section {print}
    '
  })"

  PRIMARY_GOAL="${PRIMARY_GOAL:-Not provided}"
  TARGET_USERS="${TARGET_USERS:-Not provided}"
  SCOPE_LEVEL="${SCOPE_LEVEL:-Not provided}"
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
    --activate-current)
      ACTIVATE_CURRENT_ONLY=1
      shift
      ;;
    --compact)
      COMPACT_MODE=1
      shift
      ;;
    --remove)
      REMOVE_TARGET="${2:-}"
      [ -n "$REMOVE_TARGET" ] || fail "--remove requires a path/slug argument"
      shift 2
      ;;
    --hard)
      REMOVE_HARD=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
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

require_cmd jq
require_cmd git

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "This helper must run inside a git repository."
fi

if [ -z "$REMOVE_TARGET" ] && { [ "$REMOVE_HARD" -eq 1 ] || [ "$ASSUME_YES" -eq 1 ]; }; then
  fail "--hard/--yes are only valid together with --remove"
fi

if [ "${RALPH_PRD_COMPACT:-0}" = "1" ] || [ "${RALPH_PRD_COMPACT:-}" = "true" ]; then
  COMPACT_MODE=1
fi

if [ "$ACTIVATE_CURRENT_ONLY" -eq 1 ]; then
  if [ ! -f "$PRD_JSON" ] || [ ! -s "$PRD_JSON" ]; then
    fail "Cannot activate: missing or empty $PRD_JSON"
  fi
  if ! jq -e '.project and .branchName and .description and (.userStories | length > 0)' "$PRD_JSON" >/dev/null 2>&1; then
    fail "Cannot activate: prd.json missing required fields or userStories"
  fi
  mark_active_standalone_prd "${PRD_JSON#$WORKSPACE_ROOT/}"
  printf 'Active standalone PRD: %s\n' "$PRD_JSON"
  printf 'Activation file: %s\n' "$ACTIVE_PRD_FILE"
  exit 0
fi

if [ -n "$REMOVE_TARGET" ]; then
  remove_prd
  exit 0
fi

require_cmd "$CODEX_BIN"

if [ "$QUICK_QUESTIONS_MODE" = "off" ]; then
  PRIMARY_GOAL="Not provided"
  TARGET_USERS="Not provided"
  SCOPE_LEVEL="Not provided"
fi

if [ -t 0 ] && { [ -z "$FEATURE_CONCEPT" ] || [ "$QUICK_QUESTIONS_MODE" != "off" ]; }; then
  collect_prd_intake_via_editor
fi

FEATURE_CONCEPT="$(printf '%s\n' "$FEATURE_CONCEPT" | sed '/^[[:space:]]*$/d')"
if [ -z "$FEATURE_CONCEPT" ]; then
  fail "Feature concept is required."
fi

if [ "$COMPACT_MODE" -eq 0 ] && should_auto_compact_mode; then
  COMPACT_MODE=1
  AUTO_COMPACT_SELECTED=1
fi

if [ "$COMPACT_MODE" -eq 0 ] && should_hint_single_slice_ui_story; then
  UI_SINGLE_SLICE_HINT=1
fi

if [ "$QUICK_QUESTIONS_MODE" = "on" ]; then
  :
fi

PRD_JSON_REL="$PRD_JSON"
if [[ "$PRD_JSON" == "$WORKSPACE_ROOT/"* ]]; then
  PRD_JSON_REL="${PRD_JSON#$WORKSPACE_ROOT/}"
fi

if [ "$COMPACT_MODE" -eq 1 ]; then
PROMPT=$(
  cat <<PROMPT_EOF
Use the \`prd\` skill and then the \`ralph\` skill, in that order.

Create a compact Ralph planning package for a tightly scoped change.

Feature concept:
$FEATURE_CONCEPT

Hard constraints/dependencies (if any):
${HARD_CONSTRAINTS:-None provided}

Quick clarifier answers (if provided):
- Primary goal: $PRIMARY_GOAL
- Target users: $TARGET_USERS
- Scope level: $SCOPE_LEVEL

Compact planning rules:
1. Keep the PRD markdown concise and execution-focused.
2. Prefer the fewest dependency-ordered stories that still keep verification evidence honest.
3. For small file-scoped work, prefer 1-2 user stories unless more are truly necessary.
4. Avoid long narrative sections or speculative detail.
5. Generate a PRD markdown file in \`scripts/ralph/tasks/prds/prd-[feature-name].md\`.
6. Convert the PRD to Ralph JSON and write it to \`$PRD_JSON_REL\`.
7. Every story acceptance criteria must include:
   - "Typecheck passes"
   - "Lint passes"
   - "Unit tests pass" (or "Tests pass" only if unit tests are not applicable)
8. For UI stories, include "Verify in browser using dev-browser skill".
9. Ensure JSON schema fields: \`project\`, \`branchName\`, \`description\`, \`userStories\`.

Return a short summary with:
- PRD markdown path
- prd.json path
- Number of user stories created
PROMPT_EOF
)
else
SINGLE_SLICE_GUIDANCE=""
if [ "$UI_SINGLE_SLICE_HINT" -eq 1 ]; then
SINGLE_SLICE_GUIDANCE=$(cat <<'GUIDANCE_EOF'

Additional guidance for this request:
- This is still a normal planning pass because browser/UI evidence is required, but treat the work as a single implementation slice unless unmistakable sequencing forces a split.
- If the same 1-2 file change can cover the UI copy update, matching regression update, and browser verification evidence, keep them in one story.
- Do not create a separate regression-only story or browser-verification-only story when those checks naturally belong to the same constrained change.
GUIDANCE_EOF
)
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
$SINGLE_SLICE_GUIDANCE

Guidance:
1. Follow the PRD skill workflow. If information is already sufficient, keep clarifying questions minimal.
2. If critical gaps remain, infer using explicit assumptions instead of blocking.
3. Generate a PRD markdown file in \`scripts/ralph/tasks/prds/prd-[feature-name].md\`.
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
fi

log "Generating PRD and prd.json via Codex skills..."
if [ "$AUTO_COMPACT_SELECTED" -eq 1 ]; then
  log "Using compact planning mode for a tightly scoped request."
fi
before_prd_state="$(mktemp)"
after_prd_state="$(mktemp)"
snapshot_prd_markdown_state > "$before_prd_state"
CODEX_ARGS=()
build_codex_exec_args CODEX_ARGS
printf '%s\n' "$PROMPT" | "$CODEX_BIN" "${CODEX_ARGS[@]}"
snapshot_prd_markdown_state > "$after_prd_state"

PRD_MARKDOWN_PATH="$(detect_changed_prd_markdown "$before_prd_state" "$after_prd_state" || true)"
rm -f "$before_prd_state" "$after_prd_state"

if [ -z "$PRD_MARKDOWN_PATH" ]; then
  # Fallback for edge cases where file metadata snapshots do not register a delta.
  PRD_MARKDOWN_PATH="$(latest_prd_markdown || true)"
fi
if [ -z "$PRD_MARKDOWN_PATH" ]; then
  fail "No PRD markdown file found in scripts/ralph/tasks/prds after generation."
fi
if [ ! -s "$WORKSPACE_ROOT/$PRD_MARKDOWN_PATH" ]; then
  fail "Generated PRD markdown missing or empty: $PRD_MARKDOWN_PATH"
fi

if [ ! -f "$PRD_JSON" ]; then
  fail "Expected prd.json at $PRD_JSON"
fi

if ! jq -e '.project and .branchName and .description and (.userStories | length > 0)' "$PRD_JSON" >/dev/null 2>&1; then
  fail "prd.json missing required fields or userStories"
fi

if ! jq -e '
  all(.userStories[];
    any(.acceptanceCriteria[]; test("(?i)(typecheck passes|typecheck.*passes|npm run typecheck.*passes)")) and
    any(.acceptanceCriteria[]; test("(?i)(lint passes|lint.*passes|npm run lint.*passes)")) and
    (
      any(.acceptanceCriteria[]; test("(?i)(unit tests pass|unit tests.*pass|npm test.*pass)")) or
      any(.acceptanceCriteria[]; test("(?i)(tests pass|tests.*pass)"))
    )
  )
' "$PRD_JSON" >/dev/null 2>&1; then
  fail "Each story must include typecheck, lint, and tests acceptance criteria"
fi

log "Done."
commit_generated_prd_markdown_if_needed "$PRD_MARKDOWN_PATH"
mark_active_standalone_prd "$PRD_JSON_REL"
printf 'PRD Markdown: %s\n' "$PRD_MARKDOWN_PATH"
printf 'PRD JSON: %s\n' "$PRD_JSON"
printf 'Stories: %s\n' "$(jq '.userStories | length' "$PRD_JSON")"
printf 'Active PRD mode: standalone (%s)\n' "$ACTIVE_PRD_FILE"
