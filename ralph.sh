#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ./ralph.sh [max_iterations] [--bootstrap-prd]

set -euo pipefail

MAX_ITERATIONS=10
BOOTSTRAP_PRD=false
ALLOW_EPIC_FALLBACK=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
ACTIVE_PRD_FILE="$SCRIPT_DIR/.active-prd"
SPRINTS_DIR="$SCRIPT_DIR/sprints"
TASKS_DIR="$SCRIPT_DIR/tasks"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
EPICS_FILE=""
ARCHIVE_DIR="$TASKS_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"
SPRINT_BRANCH_PREFIX="ralph/sprint"

WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PLAYWRIGHT_CLI_DIR="$WORKSPACE_ROOT/.playwright-cli"
CODEX_BIN="${CODEX_BIN:-codex}"
CODEX_LAST_MESSAGE_LATEST_FILE="$SCRIPT_DIR/.codex-last-message.txt"
CODEX_PRD_BOOTSTRAP_LAST_MESSAGE_FILE="$SCRIPT_DIR/.codex-last-message-prd-bootstrap.txt"
PRIME_CMD="$SCRIPT_DIR/ralph-prime.sh"

for arg in "$@"; do
  case "$arg" in
    --bootstrap-prd)
      BOOTSTRAP_PRD=true
      ;;
    --allow-epic-fallback)
      ALLOW_EPIC_FALLBACK=true
      ;;
    -h|--help)
      echo "Usage: ./ralph.sh [max_iterations] [--bootstrap-prd] [--allow-epic-fallback]"
      echo ""
      echo "Options:"
      echo "  --bootstrap-prd     Attempt to auto-generate scripts/ralph/prd.json when missing/empty."
      echo "  --allow-epic-fallback  Allow switching from completed standalone PRD back into epic priming."
      echo ""
      echo "Environment:"
      echo "  RALPH_BOOTSTRAP_PRD=1  Enable PRD bootstrap behavior."
      exit 0
      ;;
    *)
      if [[ "$arg" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$arg"
      else
        echo "Unknown argument: $arg" >&2
        echo "Use --help for usage." >&2
        exit 1
      fi
      ;;
  esac
done

if [ "${RALPH_BOOTSTRAP_PRD:-0}" = "1" ] || [ "${RALPH_BOOTSTRAP_PRD:-}" = "true" ]; then
  BOOTSTRAP_PRD=true
fi
if [ "${RALPH_ALLOW_EPIC_FALLBACK:-0}" = "1" ] || [ "${RALPH_ALLOW_EPIC_FALLBACK:-}" = "true" ]; then
  ALLOW_EPIC_FALLBACK=true
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

get_active_sprint() {
  if [ -f "$ACTIVE_SPRINT_FILE" ]; then
    awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE"
    return 0
  fi
  return 1
}

sprint_branch_name() {
  local sprint="$1"
  printf '%s/%s' "$SPRINT_BRANCH_PREFIX" "$sprint"
}

default_base_branch() {
  if git show-ref --verify --quiet refs/heads/master; then
    printf 'master\n'
    return 0
  fi
  if git show-ref --verify --quiet refs/heads/main; then
    printf 'main\n'
    return 0
  fi
  echo "Could not find base branch (master or main)." >&2
  return 1
}

resolve_sprint_paths() {
  local active_sprint
  active_sprint="$(get_active_sprint || true)"
  if [ -z "$active_sprint" ]; then
    EPICS_FILE=""
    ARCHIVE_DIR="$TASKS_DIR/archive"
    return 0
  fi
  EPICS_FILE="$SPRINTS_DIR/$active_sprint/epics.json"
  ARCHIVE_DIR="$TASKS_DIR/archive/$active_sprint"
  return 0
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

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\/&]/\\&/g'
}

file_has_non_whitespace() {
  local path="$1"
  [ -f "$path" ] || return 1
  grep -q '[^[:space:]]' "$path"
}

local_prompt_has_named_blocks() {
  local path="$1"
  [ -f "$path" ] || return 1
  grep -Eq '^[[:space:]]*<!--[[:space:]]*RALPH:LOCAL:[A-Za-z0-9:_-]+[[:space:]]*-->[[:space:]]*$' "$path"
}

local_prompt_block_keys() {
  local path="$1"
  awk '
    match($0, /^[[:space:]]*<!--[[:space:]]*RALPH:LOCAL:([A-Za-z0-9:_-]+)[[:space:]]*-->[[:space:]]*$/, m) {
      key = m[1]
      if (!seen[key]++) print key
    }
  ' "$path"
}

prompt_has_matching_local_marker() {
  local local_prompt_path="$1"
  local prompt_path="$2"
  local key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if grep -Eq "^[[:space:]]*<!--[[:space:]]*RALPH:LOCAL:${key}[[:space:]]*-->[[:space:]]*$" "$prompt_path"; then
      return 0
    fi
  done < <(local_prompt_block_keys "$local_prompt_path")
  return 1
}

inject_local_prompt_blocks() {
  local local_prompt_path="$1"
  local rendered_prompt_path="$2"

  awk '
    FNR == NR {
      if (match($0, /^[[:space:]]*<!--[[:space:]]*RALPH:LOCAL:([A-Za-z0-9:_-]+)[[:space:]]*-->[[:space:]]*$/, m)) {
        current = m[1]
        in_block = 1
        if (!(current in block_order_seen)) {
          block_order[++block_count] = current
          block_order_seen[current] = 1
          block_content[current] = ""
        }
        next
      }

      if (match($0, /^[[:space:]]*<!--[[:space:]]*\/RALPH:LOCAL:([A-Za-z0-9:_-]+)[[:space:]]*-->[[:space:]]*$/, m)) {
        if (in_block && m[1] == current) {
          in_block = 0
          current = ""
        }
        next
      }

      if (in_block) {
        block_content[current] = block_content[current] $0 ORS
      }
      next
    }

    {
      if (match($0, /^([[:space:]]*)<!--[[:space:]]*RALPH:LOCAL:([A-Za-z0-9:_-]+)[[:space:]]*-->[[:space:]]*$/, m)) {
        indent = m[1]
        key = m[2]
        if (key in block_content) {
          line_count = split(block_content[key], lines, /\n/)
          min_leading = -1
          for (i = 1; i <= line_count; i++) {
            if (i == line_count && lines[i] == "") {
              continue
            }
            if (lines[i] == "") {
              continue
            }
            non_ws_pos = match(lines[i], /[^ \t]/)
            if (non_ws_pos == 0) {
              leading = length(lines[i])
            } else {
              leading = non_ws_pos - 1
            }
            if (min_leading == -1 || leading < min_leading) {
              min_leading = leading
            }
          }
          if (min_leading < 0) {
            min_leading = 0
          }
          for (i = 1; i <= line_count; i++) {
            if (i == line_count && lines[i] == "") {
              continue
            }
            if (lines[i] == "") {
              print ""
            } else {
              normalized_line = lines[i]
              if (min_leading > 0) {
                normalized_line = substr(normalized_line, min_leading + 1)
              }
              print indent normalized_line
            }
          }
          next
        }
      }
      print
    }
  ' "$local_prompt_path" "$rendered_prompt_path"
}

slugify_branch() {
  printf '%s' "$1" \
    | sed 's|^ralph/||' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's|[^a-z0-9._-]+|-|g' \
    | sed -E 's|^-+||; s|-+$||'
}

has_archived_run_for_branch() {
  local branch="$1"
  local manifest
  [ -d "$ARCHIVE_DIR" ] || return 1

  while IFS= read -r manifest; do
    [ -f "$manifest" ] || continue
    if [ "$(awk -F= '/^source_branch=/{print $2}' "$manifest" | tail -n 1)" = "$branch" ]; then
      return 0
    fi
  done < <(find "$ARCHIVE_DIR" -maxdepth 2 -type f -name 'archive-manifest.txt' 2>/dev/null | sort)

  return 1
}

reset_local_run_artifacts() {
  local iter_log

  rm -f "$CODEX_LAST_MESSAGE_LATEST_FILE"
  for iter_log in "$SCRIPT_DIR"/.codex-last-message-iter-*.txt; do
    [ -f "$iter_log" ] || continue
    rm -f "$iter_log"
  done
  [ -d "$PLAYWRIGHT_CLI_DIR" ] && rm -rf "$PLAYWRIGHT_CLI_DIR"

  {
    echo "# Ralph Progress Log"
    echo "Started: $(date)"
    echo "---"
  } > "$PROGRESS_FILE"
}

has_live_run_artifacts() {
  local iter_log
  for iter_log in "$SCRIPT_DIR"/.codex-last-message-iter-*.txt; do
    [ -f "$iter_log" ] && return 0
  done

  [ -d "$PLAYWRIGHT_CLI_DIR" ] && return 0
  return 1
}

render_prompt() {
  local ralph_dir prd_file progress_file local_prompt_file rendered_prompt_file
  ralph_dir="$(escape_sed_replacement "$SCRIPT_DIR")"
  prd_file="$(escape_sed_replacement "$PRD_FILE")"
  progress_file="$(escape_sed_replacement "$PROGRESS_FILE")"
  local_prompt_file="$SCRIPT_DIR/prompt.local.md"
  rendered_prompt_file="$(mktemp)"

  sed \
    -e "s|{{RALPH_DIR}}|$ralph_dir|g" \
    -e "s|{{PRD_FILE}}|$prd_file|g" \
    -e "s|{{PROGRESS_FILE}}|$progress_file|g" \
    "$SCRIPT_DIR/prompt.md" >"$rendered_prompt_file"

  if ! file_has_non_whitespace "$local_prompt_file"; then
    cat "$rendered_prompt_file"
    rm -f "$rendered_prompt_file"
    return 0
  fi

  if local_prompt_has_named_blocks "$local_prompt_file" && prompt_has_matching_local_marker "$local_prompt_file" "$SCRIPT_DIR/prompt.md"; then
    inject_local_prompt_blocks "$local_prompt_file" "$rendered_prompt_file"
    rm -f "$rendered_prompt_file"
    return 0
  fi

  cat "$rendered_prompt_file"
  rm -f "$rendered_prompt_file"
  printf '\n\n## Local Prompt Extensions\n'
  printf '(Loaded from `%s`; preserved across framework updates.)\n\n' "$local_prompt_file"
  cat "$local_prompt_file"
}

has_complete_token() {
  local path="$1"
  [ -f "$path" ] || return 1
  grep -q "<promise>COMPLETE</promise>" "$path"
}

prd_all_passes() {
  [ -f "$PRD_FILE" ] || return 1
  jq -e '(.userStories | length) > 0 and all(.userStories[]; .passes == true)' "$PRD_FILE" >/dev/null 2>&1
}

prd_has_unfinished_stories() {
  [ -f "$PRD_FILE" ] || return 1
  jq -e '(.userStories | length) > 0 and any(.userStories[]; .passes != true)' "$PRD_FILE" >/dev/null 2>&1
}

is_prd_empty() {
  [ ! -f "$PRD_FILE" ] || [ ! -s "$PRD_FILE" ] || ! grep -q '[^[:space:]]' "$PRD_FILE"
}

prd_is_valid_json() {
  [ -f "$PRD_FILE" ] && jq -e '.' "$PRD_FILE" >/dev/null 2>&1
}

get_active_prd_mode() {
  [ -f "$ACTIVE_PRD_FILE" ] || return 1
  jq -r '.mode // empty' "$ACTIVE_PRD_FILE" 2>/dev/null
}

standalone_prd_is_active() {
  [ "$(get_active_prd_mode || true)" = "standalone" ]
}

infer_prd_mode_from_branch() {
  local prd_branch
  prd_is_valid_json || return 1
  prd_branch="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || true)"
  if [[ "$prd_branch" =~ ^ralph/epic-[0-9]+$ ]] || [[ "$prd_branch" =~ ^ralph/[^/]+/epic-[0-9]+$ ]]; then
    printf 'epic\n'
  else
    printf 'standalone\n'
  fi
}

infer_epic_id_from_branch_path() {
  local branch_path="$1"
  if [[ "$branch_path" =~ ^ralph/epic-([0-9]+)$ ]]; then
    printf 'EPIC-%03d\n' "$((10#${BASH_REMATCH[1]}))"
    return 0
  fi
  if [[ "$branch_path" =~ ^ralph/[^/]+/epic-([0-9]+)$ ]]; then
    printf 'EPIC-%03d\n' "$((10#${BASH_REMATCH[1]}))"
    return 0
  fi
  printf ''
  return 1
}

write_active_prd_state() {
  local mode="$1"
  local source_path="${2:-scripts/ralph/prd.json}"
  local epic_id=""
  local base_branch=""
  if [ "$mode" = "epic" ]; then
    local prd_branch
    prd_branch="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || true)"
    epic_id="$(infer_epic_id_from_branch_path "$prd_branch" || true)"
    local active_sprint
    active_sprint="$(get_active_sprint || true)"
    if [ -n "$active_sprint" ]; then
      base_branch="$(sprint_branch_name "$active_sprint")"
    fi
  else
    base_branch="$(default_base_branch || true)"
  fi
  cat >"$ACTIVE_PRD_FILE" <<EOF
{
  "mode": "$mode",
  "baseBranch": "${base_branch}",
  "sourcePath": "$source_path",
  "epicId": "${epic_id}",
  "activatedAt": "$(date -Iseconds)"
}
EOF
}

sync_active_prd_mode_with_current_prd() {
  local inferred_mode active_mode
  inferred_mode="$(infer_prd_mode_from_branch || true)"
  [ -n "$inferred_mode" ] || return 0
  active_mode="$(get_active_prd_mode || true)"
  if [ -z "$active_mode" ] || [ "$active_mode" != "$inferred_mode" ]; then
    write_active_prd_state "$inferred_mode" "scripts/ralph/prd.json"
    echo "Updated scripts/ralph/.active-prd mode to '$inferred_mode' based on current PRD branch."
  fi
}

build_codex_exec_args() {
  local output_last_message_file="${1:-}"
  local -n out_args_ref="$2"

  if supports_codex_yolo; then
    out_args_ref=(--yolo exec -C "$WORKSPACE_ROOT" -)
  else
    out_args_ref=(exec --dangerously-bypass-approvals-and-sandbox -C "$WORKSPACE_ROOT" -)
  fi

  if [ -n "$output_last_message_file" ]; then
    out_args_ref+=("--output-last-message" "$output_last_message_file")
  fi
}

bootstrap_prd_json() {
  local bootstrap_prompt bootstrap_output codex_args=()
  bootstrap_prompt=$(
    cat <<'EOF'
`scripts/ralph/prd.json` is missing or empty.

Use the `prd` skill to generate a concise PRD from current repository context, then use the `ralph` skill to convert it to `scripts/ralph/prd.json`.

Requirements:
- Produce valid JSON in `scripts/ralph/prd.json`
- Include: `project`, `branchName`, `description`, `userStories`
- Keep stories small and execution-ready for Ralph loop iterations
EOF
  )

  echo "PRD is missing/empty. Bootstrapping via Codex (prd + ralph skills)..."
  build_codex_exec_args "$CODEX_PRD_BOOTSTRAP_LAST_MESSAGE_FILE" codex_args
  bootstrap_output=$(printf '%s\n' "$bootstrap_prompt" | "$CODEX_BIN" "${codex_args[@]}" 2>&1) || true

  if echo "$bootstrap_output" | grep -qi "error"; then
    echo "Warning: bootstrap run reported errors; validating prd.json..."
  fi

  if is_prd_empty || ! prd_is_valid_json; then
    echo "PRD bootstrap failed: scripts/ralph/prd.json is still missing/empty/invalid JSON." >&2
    return 1
  fi

  echo "PRD bootstrap complete."
}

ensure_prd_ready() {
  if is_prd_empty; then
    if [ "$BOOTSTRAP_PRD" = "true" ]; then
      bootstrap_prd_json || return 1
    else
      echo "PRD file is missing or empty: $PRD_FILE" >&2
      echo "Create a PRD before running Ralph (then convert to scripts/ralph/prd.json)." >&2
      echo "Or rerun with --bootstrap-prd (or RALPH_BOOTSTRAP_PRD=1) to auto-bootstrap." >&2
      return 1
    fi
  fi

  if ! prd_is_valid_json; then
    echo "Invalid PRD JSON: $PRD_FILE" >&2
    return 1
  fi

  return 0
}

ensure_feature_branch_for_active_prd() {
  local feature_branch current_branch active_sprint sprint_branch base_branch
  feature_branch="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || true)"
  [ -n "$feature_branch" ] || return 0

  if ! git show-ref --verify --quiet "refs/heads/$feature_branch"; then
    active_sprint="$(get_active_sprint || true)"
    if [ -n "$active_sprint" ]; then
      sprint_branch="$(sprint_branch_name "$active_sprint")"
      if git show-ref --verify --quiet "refs/heads/$sprint_branch"; then
        git branch "$feature_branch" "$sprint_branch"
        echo "Created feature branch $feature_branch from sprint branch $sprint_branch."
      else
        base_branch="$(default_base_branch)"
        git branch "$feature_branch" "$base_branch"
        echo "Created feature branch $feature_branch from base branch $base_branch (sprint branch missing)."
      fi
    else
      base_branch="$(default_base_branch)"
      git branch "$feature_branch" "$base_branch"
      echo "Created feature branch $feature_branch from base branch $base_branch."
    fi
  fi

  current_branch="$(git branch --show-current)"
  if [ "$current_branch" != "$feature_branch" ]; then
    git checkout "$feature_branch" >/dev/null
    echo "Checked out feature branch: $feature_branch"
  fi
}

try_prime_prd() {
  if standalone_prd_is_active && prd_has_unfinished_stories; then
    echo "Standalone PRD is active with unfinished stories; skipping epic prime."
    return 0
  fi
  if standalone_prd_is_active && prd_all_passes && [ "$ALLOW_EPIC_FALLBACK" != "true" ]; then
    echo "Standalone PRD is complete. Refusing implicit epic fallback." >&2
    echo "Run ./scripts/ralph/ralph-commit.sh for standalone completion, then rerun with --allow-epic-fallback when ready." >&2
    return 1
  fi

  if [ ! -f "$PRIME_CMD" ]; then
    return 0
  fi

  bash "$PRIME_CMD" --auto
}

ensure_transient_files_not_tracked() {
  local tracked
  tracked="$(git ls-files -- "$PRD_FILE" "$PROGRESS_FILE" || true)"
  if [ -n "$tracked" ]; then
    echo "Ralph transient files must not be git-tracked:" >&2
    printf '%s\n' "$tracked" >&2
    echo "Run: git rm --cached scripts/ralph/prd.json scripts/ralph/progress.txt" >&2
    return 1
  fi
  return 0
}

ensure_no_transient_commits_in_range() {
  local from_ref="$1"
  local to_ref="$2"
  local leaked
  leaked="$(
    git log --name-only --pretty=format: "$from_ref..$to_ref" -- "$PRD_FILE" "$PROGRESS_FILE" 2>/dev/null \
      | sed '/^$/d' \
      | sort -u || true
  )"
  if [ -n "$leaked" ]; then
    echo "Ralph transient files were committed during this iteration (disallowed):" >&2
    printf '%s\n' "$leaked" >&2
    echo "Do not use git add -f/--force for transient files." >&2
    echo "Repair with: git rm --cached scripts/ralph/prd.json scripts/ralph/progress.txt" >&2
    return 1
  fi
  return 0
}

ensure_backlog_inputs_committed() {
  [ -n "${EPICS_FILE:-}" ] || return 0
  [ -f "$EPICS_FILE" ] || return 0

  local pending
  pending="$(git status --porcelain -- "$EPICS_FILE" || true)"
  if [ -n "$pending" ]; then
    echo "Commit epic backlog state before starting Ralph loop:" >&2
    printf '%s\n' "$pending" >&2
    echo "Required: commit active sprint epics.json changes first." >&2
    return 1
  fi
  return 0
}

commit_prime_epic_state_if_needed() {
  [ -n "${EPICS_FILE:-}" ] || return 0
  [ -f "$EPICS_FILE" ] || return 0

  local status_line epic_id epic_title
  status_line="$(git status --porcelain -- "$EPICS_FILE" || true)"
  [ -n "$status_line" ] || return 0

  if ! jq -e '.epics and (.epics|type=="array")' "$EPICS_FILE" >/dev/null 2>&1; then
    echo "Cannot auto-commit primed epic state: invalid $EPICS_FILE" >&2
    return 1
  fi

  epic_id="$(jq -r '.activeEpicId // empty' "$EPICS_FILE")"
  if [ -n "$epic_id" ]; then
    epic_title="$(jq -r --arg id "$epic_id" '.epics[] | select(.id == $id) | .title // empty' "$EPICS_FILE")"
  else
    epic_title=""
  fi

  git add "$EPICS_FILE"
  if git diff --cached --quiet; then
    return 0
  fi

  if [ -n "$epic_id" ]; then
    git commit -m "chore(ralph): prime $epic_id active for loop startup"
    echo "Committed primed epic state: $epic_id ${epic_title:+- $epic_title}"
  else
    git commit -m "chore(ralph): sync epic backlog state before loop"
    echo "Committed epic backlog state before loop start."
  fi
}

infer_epic_id_from_prd_branch() {
  local prd_branch="$1"
  infer_epic_id_from_branch_path "$prd_branch"
}

ensure_epic_status_synced_with_prd() {
  local prd_branch epic_id epic_status

  [ -f "$EPICS_FILE" ] || return 0
  jq -e '.epics and (.epics|type=="array")' "$EPICS_FILE" >/dev/null 2>&1 || return 0
  prd_is_valid_json || return 0

  prd_branch="$(jq -r '.branchName // empty' "$PRD_FILE")"
  [ -n "$prd_branch" ] || return 0

  epic_id="$(infer_epic_id_from_prd_branch "$prd_branch" || true)"
  [ -n "$epic_id" ] || return 0

  if ! jq -e --arg id "$epic_id" '.epics[] | select(.id == $id)' "$EPICS_FILE" >/dev/null 2>&1; then
    echo "PRD branch $prd_branch does not map to an epic present in active sprint epics.json." >&2
    return 1
  fi

  epic_status="$(jq -r --arg id "$epic_id" '.epics[] | select(.id == $id) | .status // ""' "$EPICS_FILE")"

  if prd_all_passes; then
    case "$epic_status" in
      done|abandoned|aborted)
        return 0
        ;;
      *)
        echo "PRD is complete but epic $epic_id is status '$epic_status'." >&2
        echo "Run ./scripts/ralph/ralph-commit.sh (or set status) before starting a new loop." >&2
        return 1
        ;;
    esac
  fi

  if prd_has_unfinished_stories; then
    case "$epic_status" in
      done|abandoned|aborted)
        echo "PRD has unfinished stories but epic $epic_id is status '$epic_status'." >&2
        echo "Re-prime or set the epic back to active/planned before loop start." >&2
        return 1
        ;;
    esac
  fi

  return 0
}

require_cmd jq
require_cmd git
require_cmd sed
require_cmd tee
require_cmd awk
require_cmd find
require_cmd tr
require_cmd "$CODEX_BIN"

if ! ensure_transient_files_not_tracked; then
  exit 1
fi

sync_active_prd_mode_with_current_prd

if ! resolve_sprint_paths; then
  exit 1
fi

# Guard before priming so auto-commit cannot absorb unrelated epics backlog edits.
if ! ensure_backlog_inputs_committed; then
  exit 1
fi

if ! try_prime_prd; then
  echo "Unable to prime PRD for next loop." >&2
  exit 1
fi

if ! commit_prime_epic_state_if_needed; then
  echo "Unable to commit primed epic state before loop." >&2
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Ralph must be run inside a git repository." >&2
  echo "Tip: run from your project root (not from $SCRIPT_DIR)." >&2
  exit 1
fi

if ! [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]] || [ "$MAX_ITERATIONS" -lt 1 ]; then
  echo "Invalid max_iterations: $MAX_ITERATIONS" >&2
  exit 1
fi

if [ ! -f "$SCRIPT_DIR/prompt.md" ]; then
  echo "Missing prompt file: $SCRIPT_DIR/prompt.md" >&2
  exit 1
fi

if ! ensure_prd_ready; then
  echo "Unable to initialize PRD file before Ralph loop: $PRD_FILE" >&2
  exit 1
fi

if ! ensure_feature_branch_for_active_prd; then
  echo "Unable to prepare active feature branch for PRD execution." >&2
  exit 1
fi

if ! ensure_epic_status_synced_with_prd; then
  exit 1
fi

# Archive previous run if branch changed
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")
  
  if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
    if has_archived_run_for_branch "$LAST_BRANCH"; then
      echo "Previous run ($LAST_BRANCH) already archived; continuing."
      reset_local_run_artifacts
      echo "   Removed stale local run artifacts from already-archived run and reset progress."
    else
      # Archive the previous run
      DATE=$(date +%Y-%m-%d)
      FOLDER_NAME=$(slugify_branch "$LAST_BRANCH")
      [ -n "$FOLDER_NAME" ] || FOLDER_NAME="ralph-run"
      ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"
      if [ -e "$ARCHIVE_FOLDER" ]; then
        ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME-$(date +%H%M%S)"
      fi
      
      echo "Archiving previous run: $LAST_BRANCH"
      mkdir -p "$ARCHIVE_FOLDER"
      MANIFEST_FILE="$ARCHIVE_FOLDER/archive-manifest.txt"

      ITER_SOURCE_COUNT=0
      for iter_log in "$SCRIPT_DIR"/.codex-last-message-iter-*.txt; do
        [ -f "$iter_log" ] || continue
        ITER_SOURCE_COUNT=$((ITER_SOURCE_COUNT + 1))
      done

      PLAYWRIGHT_SOURCE_PRESENT=0
      [ -d "$PLAYWRIGHT_CLI_DIR" ] && PLAYWRIGHT_SOURCE_PRESENT=1

      [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
      [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
      [ -f "$SCRIPT_DIR/.codex-last-message.txt" ] && cp "$SCRIPT_DIR/.codex-last-message.txt" "$ARCHIVE_FOLDER/"
      for iter_log in "$SCRIPT_DIR"/.codex-last-message-iter-*.txt; do
        [ -f "$iter_log" ] || continue
        cp "$iter_log" "$ARCHIVE_FOLDER/"
      done
      [ -d "$PLAYWRIGHT_CLI_DIR" ] && cp -a "$PLAYWRIGHT_CLI_DIR" "$ARCHIVE_FOLDER/"

      ITER_ARCHIVE_COUNT=$(find "$ARCHIVE_FOLDER" -maxdepth 1 -type f -name '.codex-last-message-iter-*.txt' | wc -l | tr -d '[:space:]')
      PLAYWRIGHT_ARCHIVE_PRESENT=0
      [ -d "$ARCHIVE_FOLDER/.playwright-cli" ] && PLAYWRIGHT_ARCHIVE_PRESENT=1

      {
        echo "archive_time=$(date -Iseconds)"
        echo "source_branch=$LAST_BRANCH"
        echo "source_iter_logs=$ITER_SOURCE_COUNT"
        echo "archived_iter_logs=$ITER_ARCHIVE_COUNT"
        echo "source_playwright_cli_present=$PLAYWRIGHT_SOURCE_PRESENT"
        echo "archived_playwright_cli_present=$PLAYWRIGHT_ARCHIVE_PRESENT"
      } > "$MANIFEST_FILE"

      if [ "$ITER_ARCHIVE_COUNT" -ne "$ITER_SOURCE_COUNT" ]; then
        echo "Archive verification failed: iteration log count mismatch (source=$ITER_SOURCE_COUNT archived=$ITER_ARCHIVE_COUNT)." >&2
        echo "Logs were NOT deleted. See: $MANIFEST_FILE" >&2
        exit 1
      fi

      if [ "$PLAYWRIGHT_SOURCE_PRESENT" -eq 1 ] && [ "$PLAYWRIGHT_ARCHIVE_PRESENT" -ne 1 ]; then
        echo "Archive verification failed: .playwright-cli missing from archive output." >&2
        echo "Artifacts were NOT deleted. See: $MANIFEST_FILE" >&2
        exit 1
      fi

      reset_local_run_artifacts
      echo "   Archived to: $ARCHIVE_FOLDER"
    fi
  fi
fi

# Track current branch
if [ -f "$PRD_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  if [ -n "$CURRENT_BRANCH" ]; then
    echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
  fi
fi

# Initialize progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Ralph Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

echo "Starting Ralph - Max iterations: $MAX_ITERATIONS"
echo "Workspace root: $WORKSPACE_ROOT"

for ((i=1; i<=MAX_ITERATIONS; i++)); do
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  Ralph Iteration $i of $MAX_ITERATIONS"
  echo "═══════════════════════════════════════════════════════"

  CODEX_ITER_LAST_MESSAGE_FILE="$SCRIPT_DIR/.codex-last-message-iter-$i.txt"
  ITERATION_START_HEAD="$(git rev-parse HEAD)"

  if ! ensure_prd_ready; then
    echo "Iteration $i aborted: PRD file is not ready."
    exit 1
  fi

  build_codex_exec_args "$CODEX_ITER_LAST_MESSAGE_FILE" CODEX_ARGS

  # Run Codex with the Ralph prompt (fresh context every iteration).
  # Avoid storing full model output in shell memory.
  render_prompt | "$CODEX_BIN" "${CODEX_ARGS[@]}" || true

  cp -f "$CODEX_ITER_LAST_MESSAGE_FILE" "$CODEX_LAST_MESSAGE_LATEST_FILE" >/dev/null 2>&1 || true

  ITERATION_END_HEAD="$(git rev-parse HEAD)"
  if [ "$ITERATION_START_HEAD" != "$ITERATION_END_HEAD" ]; then
    if ! ensure_no_transient_commits_in_range "$ITERATION_START_HEAD" "$ITERATION_END_HEAD"; then
      exit 1
    fi
  fi

  if ! ensure_transient_files_not_tracked; then
    exit 1
  fi
  
  # Check for completion signal
  if has_complete_token "$CODEX_ITER_LAST_MESSAGE_FILE" || prd_all_passes; then
    echo ""
    echo "Ralph completed all tasks!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    exit 0
  fi
  
  echo "Iteration $i complete. Continuing..."
  sleep 2
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
exit 1
