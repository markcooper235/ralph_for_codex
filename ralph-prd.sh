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
SPEC_CHECK="$SCRIPT_DIR/ralph-spec-check.sh"
SPEC_STRENGTHEN="$SCRIPT_DIR/ralph-spec-strengthen.sh"
SPEC_STRENGTHEN_ATTEMPTS=3

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
FIRST_SLICE_HINT="Not provided"
INVARIANTS_HINT="Not provided"
SUPPORTING_FILES_HINT="Not provided"
PROOF_HINTS="Not provided"
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

planning_request_lower() {
  printf '%s\n%s\n' "$FEATURE_CONCEPT" "$HARD_CONSTRAINTS" | tr '[:upper:]' '[:lower:]'
}

feature_concept_length() {
  printf '%s' "$FEATURE_CONCEPT" | wc -c | tr -d ' '
}

has_explicit_file_scope_request() {
  local lower="$1"
  case "$lower" in
    *"keep changes limited to "*|*"only change "*|*"limited to "*)
      return 0
      ;;
  esac
  return 1
}

is_complex_or_cross_cutting_request() {
  local lower="$1"
  case "$lower" in
    *auth*|*session*|*database*|*migration*|*schema*|*routing*|*router*|*provider*|*permission*|*"api contract"*|*"shared state"*|*"event pipeline"*|*"global config"*|*refactor*|*architecture*|*epic*|*sprint*|*cross-cutting*|*shared\ hook*|*shared\ component*|*state\ management*|*playwright*|*cypress*)
      return 0
      ;;
  esac
  return 1
}

is_ui_request() {
  local lower="$1"
  case "$lower" in
    *browser*|*ui*|*"#app"*|*render*)
      return 0
      ;;
  esac
  return 1
}

matches_tight_scoped_request() {
  local lower="$1"
  local max_feature_len="$2"
  local path_count feature_len

  path_count="$(count_distinct_file_paths)"
  feature_len="$(feature_concept_length)"

  has_explicit_file_scope_request "$lower" || return 1
  [ "$path_count" -ge 1 ] && [ "$path_count" -le 2 ] || return 1
  [ "$feature_len" -le "$max_feature_len" ] || return 1
  return 0
}

should_auto_compact_mode() {
  local lower
  lower="$(planning_request_lower)"

  is_complex_or_cross_cutting_request "$lower" && return 1
  is_ui_request "$lower" && return 1
  matches_tight_scoped_request "$lower" 120
}

should_hint_single_slice_ui_story() {
  local lower
  lower="$(planning_request_lower)"

  is_ui_request "$lower" || return 1
  is_complex_or_cross_cutting_request "$lower" && return 1
  matches_tight_scoped_request "$lower" 200
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

planning_context_block() {
  cat <<EOF
Feature concept:
$FEATURE_CONCEPT

Hard constraints/dependencies (if any):
${HARD_CONSTRAINTS:-None provided}

Quick clarifier answers (if provided):
- Primary goal: $PRIMARY_GOAL
- Target users: $TARGET_USERS
- Scope level: $SCOPE_LEVEL
- First slice hint: $FIRST_SLICE_HINT
- Preserved invariants: $INVARIANTS_HINT
- Supporting files: $SUPPORTING_FILES_HINT
- Proof hints: $PROOF_HINTS
EOF
}

planning_output_contract_block() {
  cat <<EOF
Required outputs:
- Generate a PRD markdown file in \`scripts/ralph/tasks/prds/prd-[feature-name].md\`.
- Convert the PRD to Ralph JSON and write it to \`$PRD_JSON_REL\`.
- Ensure JSON schema fields: \`project\`, \`branchName\`, \`description\`, \`userStories\`.
EOF
}

planning_shared_rules_block() {
  cat <<'EOF'
Shared rules:
1. Fit the PRD into 1-6 executable stories.
2. Use task classes that naturally fit that range:
   - micro: 1 story
   - small: 2-3 stories
   - medium: 4-6 stories
3. If honest decomposition would require more than 6 stories, create the best 1-6 story slice for this PRD and explicitly recommend a follow-up PRD for the deferred scope.
4. Every story must be dependency-ordered and execution-ready.
5. Every story must contain both:
   - a plain `Acceptance Criteria` heading followed by only `- Must ...` bullets
   - a plain `Proof Obligations` heading followed by only `- Must ...` bullets
6. Every story must include at least one proof-obligation bullet using checker-recognized wording such as:
   - "Typecheck passes"
   - "Lint passes"
   - "Unit tests pass"
   - "Tests pass"
   - "Verify in browser"
   - "Playwright"
   - "Cypress"
   - "verification"
7. For UI stories, include at least one proof obligation using the literal wording "Verify in browser".
8. The markdown must be loop-ready, not merely descriptive. Include explicit sections for:
   - `## Scope`
   - `## Out of Scope`
   - `## Execution Model`
   - `## First Slice Expectations`
   - `## Allowed Supporting Files`
   - `## Preserved Invariants`
   - `## User Stories`
   - `## Refinement Checkpoints`
   - `## Definition of Done`
9. Story headings must use the exact format `### Story N: Title`.
10. Each story must contain both a plain `Acceptance Criteria` heading and a plain `Proof Obligations` heading.
11. `## First Slice Expectations` must name both using explicit labels or equivalent literal wording:
   - `exact source:` and `destination:`
   - `entrypoint:`, `caller workflow:`, `workflow:`, or `commands:`
12. `## Execution Model` must explicitly use wording that covers at least two of:
   - `first slice`, `sequence`, `order`, or `dependency`
   - `support`, `scope`, or `supporting`
   - `verify`, `verification`, `proof`, `targeted`, or `full`
13. `## Allowed Supporting Files` must proactively name realistic support files or file families such as tests, scripts, package/config files, verification files, or workflows when they are relevant to execution.
14. `## Preserved Invariants` must contain at least 2 explicit bullets describing behaviors or rules that remain stable/unchanged.
15. `## Refinement Checkpoints` must contain at least one concrete checkpoint bullet.
16. Avoid vague phrases such as "as needed", "if applicable", "if helpful", "appropriate", "and/or", or "etc." in the markdown, acceptance criteria, or proof obligations.
17. Add structured scope metadata proactively:
   - top-level `scopePaths`: exact repo-relative file paths only when the whole PRD is tightly scoped
   - per-story `scopePaths`: exact repo-relative file paths or support-file families made explicit by the markdown
   - use empty arrays only when exact scope genuinely is not knowable yet
18. Include helper scripts, build scripts, configs, fixtures, workflows, or package metadata in `scopePaths` when the feature explicitly or naturally requires them.
19. If a story changes source files, include in that same story any tests or verification files that Ralph targeted verification will naturally infer from those source paths; do not defer those proof files to a later story when the earlier story would otherwise fail verification.
20. Keep the markdown and JSON concise and token-efficient. Prefer short bullets and direct constraints over explanatory prose.
21. After writing files, do not print PRD markdown, JSON contents, file diffs, or file-update blocks.
22. Do not repeat the same summary twice.
23. The generated markdown should pass `scripts/ralph/ralph-spec-check.sh` immediately without needing a strengthen pass.
24. Final output must be 3 lines only:
   - `PRD markdown path: ...`
   - `prd.json path: ...`
   - `Number of user stories created: ...`
EOF
}

compact_mode_rules_block() {
  cat <<'EOF'
Compact planning rules:
1. Keep the PRD markdown concise and execution-focused.
2. Prefer the fewest dependency-ordered stories that still keep verification evidence honest.
3. For small file-scoped work, prefer 1-2 user stories unless more are truly necessary.
4. Avoid long narrative sections or speculative detail.
EOF
}

normal_mode_guidance_block() {
  local extra_guidance="$1"
  cat <<EOF
Guidance:
1. If critical gaps remain, infer using explicit assumptions instead of blocking.
2. Break work into small, one-iteration user stories ordered by dependency.
3. Set clear story priorities (1..N in execution order).$extra_guidance
EOF
}

build_planning_prompt() {
  local mode="$1"
  local mode_header="" mode_rules=""

  if [ "$mode" = "compact" ]; then
    mode_header="Create a compact Ralph planning package for a tightly scoped change."
    mode_rules="$(compact_mode_rules_block)"
  else
    mode_header="Create a complete Ralph planning package from this feature concept."
    mode_rules="$(normal_mode_guidance_block "$2")"
  fi

  cat <<EOF
Use the \`prd\` skill and then the \`ralph\` skill, in that order.

$mode_header

$PROMPT_CONTEXT
$mode_rules

$PROMPT_OUTPUTS

$PROMPT_SHARED_RULES

Return only those 3 lines.
EOF
}

convert_markdown_prd_to_json() {
  local markdown_rel="$1"
  local prompt codex_args=()

  prompt=$(
    cat <<EOF
Use the \`ralph\` skill.

Convert this loop-ready PRD markdown into Ralph JSON:
- Source: \`$markdown_rel\`
- Destination: \`$PRD_JSON_REL\`

Requirements:
1. Produce valid JSON with keys: project, branchName, description, userStories.
2. Preserve the markdown's execution-ready details, especially first slice expectations, allowed supporting files, preserved invariants, and proof obligations.
3. Keep user stories dependency-ordered and execution-ready.
4. Add proactive \`scopePaths\` arrays when the markdown makes realistic support-file scope explicit, including config, package metadata, scripts, workflows, and tests when naturally required.
5. Do not under-scope stories by omitting required support files that the markdown explicitly puts in scope.
6. If a story changes source files, include in that same story any tests or verification files that Ralph targeted verification will naturally infer from those source paths; do not defer those proof files to a later story when the earlier story would otherwise fail verification.
7. Keep the JSON concise and token-efficient. Avoid long descriptions or repetitive notes when shorter wording is equally precise.

Return only a short summary after writing the file.
EOF
  )

  build_codex_exec_args codex_args
  printf '%s\n' "$prompt" | "$CODEX_BIN" "${codex_args[@]}"
}

ensure_markdown_spec_ready() {
  local markdown_abs="$1"
  local attempt=1

  while [ "$attempt" -le "$SPEC_STRENGTHEN_ATTEMPTS" ]; do
    if "$SPEC_CHECK" "$markdown_abs" >/dev/null; then
      return 0
    fi

    log "Spec check failed for ${markdown_abs#$WORKSPACE_ROOT/} (attempt $attempt/$SPEC_STRENGTHEN_ATTEMPTS); strengthening..."
    if ! "$SPEC_STRENGTHEN" "$markdown_abs"; then
      fail "Spec strengthening failed for ${markdown_abs#$WORKSPACE_ROOT/}. Provide stronger starting context and retry."
    fi
    attempt=$((attempt + 1))
  done

  if "$SPEC_CHECK" "$markdown_abs" >/dev/null; then
    return 0
  fi

  fail "Spec for ${markdown_abs#$WORKSPACE_ROOT/} is still too weak after $SPEC_STRENGTHEN_ATTEMPTS strengthening attempts. Provide stronger starting context and retry."
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
    echo "- Keep PRIMARY_GOAL/TARGET_USERS/SCOPE_LEVEL/FIRST_SLICE_HINT as single-line summaries when possible."
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
  FIRST_SLICE_HINT="$(printf '%s\n' "$intake_block" | kv_from_block "FIRST_SLICE_HINT" | trim_whitespace)"

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
      /^FIRST_SLICE_HINT:[[:space:]]*$/ {in_section=0}
      in_section {print}
    '
  })"

  INVARIANTS_HINT="$({
    printf '%s\n' "$intake_block" | awk '
      /^INVARIANTS:[[:space:]]*$/ {in_section=1; next}
      /^SUPPORTING_FILES:[[:space:]]*$/ {in_section=0}
      in_section {print}
    '
  })"

  SUPPORTING_FILES_HINT="$({
    printf '%s\n' "$intake_block" | awk '
      /^SUPPORTING_FILES:[[:space:]]*$/ {in_section=1; next}
      /^PROOF_HINTS:[[:space:]]*$/ {in_section=0}
      in_section {print}
    '
  })"

  PROOF_HINTS="$({
    printf '%s\n' "$intake_block" | awk '
      /^PROOF_HINTS:[[:space:]]*$/ {in_section=1; next}
      in_section {print}
    '
  })"

  PRIMARY_GOAL="${PRIMARY_GOAL:-Not provided}"
  TARGET_USERS="${TARGET_USERS:-Not provided}"
  SCOPE_LEVEL="${SCOPE_LEVEL:-Not provided}"
  FIRST_SLICE_HINT="${FIRST_SLICE_HINT:-Not provided}"
  INVARIANTS_HINT="${INVARIANTS_HINT:-Not provided}"
  SUPPORTING_FILES_HINT="${SUPPORTING_FILES_HINT:-Not provided}"
  PROOF_HINTS="${PROOF_HINTS:-Not provided}"
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
require_cmd "$SPEC_CHECK"
require_cmd "$SPEC_STRENGTHEN"

if [ "$QUICK_QUESTIONS_MODE" = "off" ]; then
  PRIMARY_GOAL="Not provided"
  TARGET_USERS="Not provided"
  SCOPE_LEVEL="Not provided"
  FIRST_SLICE_HINT="Not provided"
  INVARIANTS_HINT="Not provided"
  SUPPORTING_FILES_HINT="Not provided"
  PROOF_HINTS="Not provided"
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

PROMPT_CONTEXT="$(planning_context_block)"
PROMPT_OUTPUTS="$(planning_output_contract_block)"
PROMPT_SHARED_RULES="$(planning_shared_rules_block)"

if [ "$COMPACT_MODE" -eq 1 ]; then
PROMPT="$(build_planning_prompt "compact")"
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
PROMPT="$(build_planning_prompt "normal" "$SINGLE_SLICE_GUIDANCE")"
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

ensure_markdown_spec_ready "$WORKSPACE_ROOT/$PRD_MARKDOWN_PATH"
convert_markdown_prd_to_json "$PRD_MARKDOWN_PATH"

if [ ! -f "$PRD_JSON" ]; then
  fail "Expected prd.json at $PRD_JSON"
fi

if ! jq -e '.project and .branchName and .description and (.userStories | length > 0)' "$PRD_JSON" >/dev/null 2>&1; then
  fail "prd.json missing required fields or userStories"
fi

if ! jq -e '
  ((.scopePaths // []) | type == "array")
  and all((.scopePaths // [])[]; type == "string")
  and all(.userStories[];
    ((.scopePaths // []) | type == "array")
    and all((.scopePaths // [])[]; type == "string")
  )
' "$PRD_JSON" >/dev/null 2>&1; then
  fail "prd.json scopePaths fields must be arrays of strings when present"
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
