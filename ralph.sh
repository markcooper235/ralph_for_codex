#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ./ralph.sh [max_iterations] [--bootstrap-prd]

set -euo pipefail

MAX_ITERATIONS=10
BOOTSTRAP_PRD=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"

WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PLAYWRIGHT_CLI_DIR="$WORKSPACE_ROOT/.playwright-cli"
CODEX_BIN="${CODEX_BIN:-codex}"
CODEX_LAST_MESSAGE_LATEST_FILE="$SCRIPT_DIR/.codex-last-message.txt"
CODEX_PRD_BOOTSTRAP_LAST_MESSAGE_FILE="$SCRIPT_DIR/.codex-last-message-prd-bootstrap.txt"

for arg in "$@"; do
  case "$arg" in
    --bootstrap-prd)
      BOOTSTRAP_PRD=true
      ;;
    -h|--help)
      echo "Usage: ./ralph.sh [max_iterations] [--bootstrap-prd]"
      echo ""
      echo "Options:"
      echo "  --bootstrap-prd     Attempt to auto-generate scripts/ralph/prd.json when missing/empty."
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

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
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

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\/&]/\\&/g'
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

has_live_run_artifacts() {
  local iter_log
  for iter_log in "$SCRIPT_DIR"/.codex-last-message-iter-*.txt; do
    [ -f "$iter_log" ] && return 0
  done

  [ -d "$PLAYWRIGHT_CLI_DIR" ] && return 0
  return 1
}

render_prompt() {
  local ralph_dir prd_file progress_file
  ralph_dir="$(escape_sed_replacement "$SCRIPT_DIR")"
  prd_file="$(escape_sed_replacement "$PRD_FILE")"
  progress_file="$(escape_sed_replacement "$PROGRESS_FILE")"

  sed \
    -e "s|{{RALPH_DIR}}|$ralph_dir|g" \
    -e "s|{{PRD_FILE}}|$prd_file|g" \
    -e "s|{{PROGRESS_FILE}}|$progress_file|g" \
    "$SCRIPT_DIR/prompt.md"
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

is_prd_empty() {
  [ ! -f "$PRD_FILE" ] || [ ! -s "$PRD_FILE" ] || ! grep -q '[^[:space:]]' "$PRD_FILE"
}

prd_is_valid_json() {
  [ -f "$PRD_FILE" ] && jq -e '.' "$PRD_FILE" >/dev/null 2>&1
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
  bootstrap_output=$(printf '%s\n' "$bootstrap_prompt" | "$CODEX_BIN" "${codex_args[@]}" 2>&1 | tee /dev/stderr) || true

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

require_cmd jq
require_cmd git
require_cmd sed
require_cmd tee
require_cmd awk
require_cmd find
require_cmd tr
require_cmd "$CODEX_BIN"

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

# Archive previous run if branch changed
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")
  
  if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
    if has_archived_run_for_branch "$LAST_BRANCH"; then
      echo "Previous run ($LAST_BRANCH) already archived; continuing."
      if has_live_run_artifacts; then
        for iter_log in "$SCRIPT_DIR"/.codex-last-message-iter-*.txt; do
          [ -f "$iter_log" ] || continue
          rm -f "$iter_log"
        done
        [ -d "$PLAYWRIGHT_CLI_DIR" ] && rm -rf "$PLAYWRIGHT_CLI_DIR"
        echo "   Removed stale local run artifacts from already-archived run."
      fi
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

      for iter_log in "$SCRIPT_DIR"/.codex-last-message-iter-*.txt; do
        [ -f "$iter_log" ] || continue
        rm -f "$iter_log"
      done
      [ -d "$PLAYWRIGHT_CLI_DIR" ] && rm -rf "$PLAYWRIGHT_CLI_DIR"
      echo "   Archived to: $ARCHIVE_FOLDER"
      
      # Reset progress file for new run
      echo "# Ralph Progress Log" > "$PROGRESS_FILE"
      echo "Started: $(date)" >> "$PROGRESS_FILE"
      echo "---" >> "$PROGRESS_FILE"
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

  if ! ensure_prd_ready; then
    echo "Iteration $i aborted: PRD file is not ready."
    exit 1
  fi

  build_codex_exec_args "$CODEX_ITER_LAST_MESSAGE_FILE" CODEX_ARGS

  # Run Codex with the Ralph prompt (fresh context every iteration)
  OUTPUT=$(render_prompt | "$CODEX_BIN" "${CODEX_ARGS[@]}" 2>&1 | tee /dev/stderr) || true

  cp -f "$CODEX_ITER_LAST_MESSAGE_FILE" "$CODEX_LAST_MESSAGE_LATEST_FILE" >/dev/null 2>&1 || true
  
  # Check for completion signal
  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>" || has_complete_token "$CODEX_ITER_LAST_MESSAGE_FILE" || prd_all_passes; then
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
