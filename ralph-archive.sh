#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"
TASKS_DIR="$SCRIPT_DIR/tasks"
ARCHIVE_ROOT="$TASKS_DIR/archive"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
ACTIVE_PRD_FILE="$SCRIPT_DIR/.active-prd"
WORKSPACE_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$WORKSPACE_ROOT" ]; then
  WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
PLAYWRIGHT_CLI_DIR="$WORKSPACE_ROOT/.playwright-cli"
ITERATION_TRANSCRIPT_LATEST_FILE="$SCRIPT_DIR/.iteration-log-latest.txt"
ITERATION_HANDOFF_LATEST_FILE="$SCRIPT_DIR/.iteration-handoff-latest.json"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

has_non_transient_worktree_changes() {
  git status --porcelain --untracked-files=all \
    | awk '
      {
        path = substr($0, 4)
        if (path ~ /^scripts\/ralph\/prd\.json$/) next
        if (path ~ /^scripts\/ralph\/progress\.txt$/) next
        if (path ~ /^scripts\/ralph\/\.active-prd$/) next
        if (path ~ /^scripts\/ralph\/\.last-branch$/) next
        if (path ~ /^scripts\/ralph\/\.iteration-log(\-iter-[0-9]+|-latest)?\.txt$/) next
        if (path ~ /^scripts\/ralph\/\.iteration-handoff(\-iter-[0-9]+|-latest)?\.json$/) next
        if (path ~ /^scripts\/ralph\/tasks(\/[^/]+)?\/?$/) next
        if (path ~ /^scripts\/ralph\/tasks\/[^/]+\/prd-epic-[^/]+\.md$/) next
        if (path ~ /^\.playwright-cli(\/|$)/) next
        print
      }
    '
}

ensure_clean_worktree() {
  if [ -n "$(has_non_transient_worktree_changes)" ]; then
    echo "Working tree is not clean. Commit or stash all changes before running ralph-archive." >&2
    echo "Hint: run 'git status --short' to review pending changes." >&2
    exit 1
  fi
}

slugify() {
  printf '%s' "$1" \
    | sed 's|^ralph/||' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's|[^a-z0-9._-]+|-|g' \
    | sed -E 's|^-+||; s|-+$||'
}

get_active_sprint() {
  if [ -f "$ACTIVE_SPRINT_FILE" ]; then
    awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE"
    return 0
  fi
  return 1
}

get_active_prd_mode() {
  if [ -f "$ACTIVE_PRD_FILE" ]; then
    jq -r '.mode // empty' "$ACTIVE_PRD_FILE" 2>/dev/null
    return 0
  fi
  return 1
}

infer_prd_mode_from_branch() {
  local prd_branch
  if [ ! -f "$PRD_FILE" ] || ! jq -e '.' "$PRD_FILE" >/dev/null 2>&1; then
    return 1
  fi
  prd_branch="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || true)"
  if [[ "$prd_branch" =~ ^ralph/epic-[A-Za-z0-9-]+$ ]] || [[ "$prd_branch" =~ ^ralph/[^/]+/epic-[A-Za-z0-9-]+$ ]]; then
    printf 'epic\n'
  else
    printf 'standalone\n'
  fi
}

iteration_ids_for_pattern() {
  local pattern="$1"
  find "$SCRIPT_DIR" -maxdepth 1 -type f -name "$pattern" -printf '%f\n' 2>/dev/null \
    | sed -E 's/.*-iter-([0-9]+)\..*/\1/' \
    | sort -n
}

paired_iteration_artifacts_valid() {
  local transcript_ids handoff_ids latest_transcript latest_handoff

  transcript_ids="$(iteration_ids_for_pattern '.iteration-log-iter-*.txt')"
  handoff_ids="$(iteration_ids_for_pattern '.iteration-handoff-iter-*.json')"

  if [ "$transcript_ids" != "$handoff_ids" ]; then
    echo "Archive verification failed: iteration transcript/handoff files are not paired." >&2
    echo "Transcripts: ${transcript_ids:-<none>}" >&2
    echo "Handoffs: ${handoff_ids:-<none>}" >&2
    return 1
  fi

  latest_transcript=0
  latest_handoff=0
  [ -f "$ITERATION_TRANSCRIPT_LATEST_FILE" ] && latest_transcript=1
  [ -f "$ITERATION_HANDOFF_LATEST_FILE" ] && latest_handoff=1
  if [ "$latest_transcript" -ne "$latest_handoff" ]; then
    echo "Archive verification failed: latest transcript/handoff presence mismatch." >&2
    return 1
  fi

  return 0
}

reset_local_run_artifacts() {
  local iter_transcript iter_handoff

  rm -f "$ITERATION_TRANSCRIPT_LATEST_FILE" "$ITERATION_HANDOFF_LATEST_FILE"
  for iter_transcript in "$SCRIPT_DIR"/.iteration-log-iter-*.txt; do
    [ -f "$iter_transcript" ] || continue
    rm -f "$iter_transcript"
  done
  for iter_handoff in "$SCRIPT_DIR"/.iteration-handoff-iter-*.json; do
    [ -f "$iter_handoff" ] || continue
    rm -f "$iter_handoff"
  done
  [ -d "$PLAYWRIGHT_CLI_DIR" ] && rm -rf "$PLAYWRIGHT_CLI_DIR"
  rm -f "$PROGRESS_FILE"
}

require_cmd jq
require_cmd git
require_cmd sed
require_cmd tr

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ralph-archive must be run inside a git repository." >&2
  exit 1
fi

ensure_clean_worktree
paired_iteration_artifacts_valid || exit 1

ACTIVE_PRD_MODE="$(get_active_prd_mode || true)"
INFERRED_PRD_MODE="$(infer_prd_mode_from_branch || true)"
if [ -n "$INFERRED_PRD_MODE" ] && [ -n "$ACTIVE_PRD_MODE" ] && [ "$INFERRED_PRD_MODE" != "$ACTIVE_PRD_MODE" ]; then
  echo "Warning: .active-prd mode '$ACTIVE_PRD_MODE' mismatches current PRD branch; using inferred mode '$INFERRED_PRD_MODE'." >&2
  ACTIVE_PRD_MODE="$INFERRED_PRD_MODE"
elif [ -n "$INFERRED_PRD_MODE" ] && [ -z "$ACTIVE_PRD_MODE" ]; then
  ACTIVE_PRD_MODE="$INFERRED_PRD_MODE"
fi
ACTIVE_SPRINT="$(get_active_sprint || true)"
if [ "$ACTIVE_PRD_MODE" = "standalone" ]; then
  ARCHIVE_ROOT="$ARCHIVE_ROOT/prds"
elif [ -n "$ACTIVE_SPRINT" ]; then
  ARCHIVE_ROOT="$ARCHIVE_ROOT/$ACTIVE_SPRINT"
else
  ARCHIVE_ROOT="$ARCHIVE_ROOT/prds"
fi

if [ ! -f "$PRD_FILE" ] && [ ! -f "$PROGRESS_FILE" ]; then
  echo "Nothing to archive: no prd.json or progress.txt in $SCRIPT_DIR" >&2
  exit 1
fi

BRANCH_NAME=""
if [ -f "$LAST_BRANCH_FILE" ]; then
  BRANCH_NAME="$(cat "$LAST_BRANCH_FILE" 2>/dev/null || true)"
fi

if [ -z "$BRANCH_NAME" ] && [ -f "$PRD_FILE" ]; then
  BRANCH_NAME="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || true)"
fi

if [ -z "$BRANCH_NAME" ]; then
  BRANCH_NAME="ralph-run"
fi

FEATURE_SLUG="$(slugify "$BRANCH_NAME")"
if [ -z "$FEATURE_SLUG" ]; then
  FEATURE_SLUG="ralph-run"
fi

DATE_PREFIX="$(date +%F)"
ARCHIVE_DIR="$ARCHIVE_ROOT/$DATE_PREFIX-$FEATURE_SLUG"
MANIFEST_FILE=""

if [ -e "$ARCHIVE_DIR" ]; then
  ARCHIVE_DIR="$ARCHIVE_ROOT/$DATE_PREFIX-$FEATURE_SLUG-$(date +%H%M%S)"
fi

mkdir -p "$ARCHIVE_DIR"
MANIFEST_FILE="$ARCHIVE_DIR/archive-manifest.txt"

TRANSCRIPT_SOURCE_COUNT=0
for iter_transcript in "$SCRIPT_DIR"/.iteration-log-iter-*.txt; do
  [ -f "$iter_transcript" ] || continue
  TRANSCRIPT_SOURCE_COUNT=$((TRANSCRIPT_SOURCE_COUNT + 1))
done

HANDOFF_SOURCE_COUNT=0
for iter_handoff in "$SCRIPT_DIR"/.iteration-handoff-iter-*.json; do
  [ -f "$iter_handoff" ] || continue
  HANDOFF_SOURCE_COUNT=$((HANDOFF_SOURCE_COUNT + 1))
done

PLAYWRIGHT_SOURCE_PRESENT=0
[ -d "$PLAYWRIGHT_CLI_DIR" ] && PLAYWRIGHT_SOURCE_PRESENT=1

[ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_DIR/"
[ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_DIR/"
[ -f "$ITERATION_TRANSCRIPT_LATEST_FILE" ] && cp "$ITERATION_TRANSCRIPT_LATEST_FILE" "$ARCHIVE_DIR/"
[ -f "$ITERATION_HANDOFF_LATEST_FILE" ] && cp "$ITERATION_HANDOFF_LATEST_FILE" "$ARCHIVE_DIR/"

for iter_transcript in "$SCRIPT_DIR"/.iteration-log-iter-*.txt; do
  [ -f "$iter_transcript" ] || continue
  cp "$iter_transcript" "$ARCHIVE_DIR/"
done
for iter_handoff in "$SCRIPT_DIR"/.iteration-handoff-iter-*.json; do
  [ -f "$iter_handoff" ] || continue
  cp "$iter_handoff" "$ARCHIVE_DIR/"
done
[ -d "$PLAYWRIGHT_CLI_DIR" ] && cp -a "$PLAYWRIGHT_CLI_DIR" "$ARCHIVE_DIR/"

TRANSCRIPT_ARCHIVE_COUNT=$(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name '.iteration-log-iter-*.txt' | wc -l | tr -d '[:space:]')
HANDOFF_ARCHIVE_COUNT=$(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name '.iteration-handoff-iter-*.json' | wc -l | tr -d '[:space:]')
PLAYWRIGHT_ARCHIVE_PRESENT=0
[ -d "$ARCHIVE_DIR/.playwright-cli" ] && PLAYWRIGHT_ARCHIVE_PRESENT=1

{
  echo "archive_time=$(date -Iseconds)"
  echo "source_branch=$BRANCH_NAME"
  echo "source_iteration_transcripts=$TRANSCRIPT_SOURCE_COUNT"
  echo "archived_iteration_transcripts=$TRANSCRIPT_ARCHIVE_COUNT"
  echo "source_iteration_handoffs=$HANDOFF_SOURCE_COUNT"
  echo "archived_iteration_handoffs=$HANDOFF_ARCHIVE_COUNT"
  echo "source_playwright_cli_present=$PLAYWRIGHT_SOURCE_PRESENT"
  echo "archived_playwright_cli_present=$PLAYWRIGHT_ARCHIVE_PRESENT"
} > "$MANIFEST_FILE"

if [ "$TRANSCRIPT_ARCHIVE_COUNT" -ne "$TRANSCRIPT_SOURCE_COUNT" ]; then
  echo "Archive verification failed: iteration transcript count mismatch (source=$TRANSCRIPT_SOURCE_COUNT archived=$TRANSCRIPT_ARCHIVE_COUNT)." >&2
  echo "Logs were NOT deleted. See: $MANIFEST_FILE" >&2
  exit 1
fi

if [ "$HANDOFF_ARCHIVE_COUNT" -ne "$HANDOFF_SOURCE_COUNT" ]; then
  echo "Archive verification failed: iteration handoff count mismatch (source=$HANDOFF_SOURCE_COUNT archived=$HANDOFF_ARCHIVE_COUNT)." >&2
  echo "Logs were NOT deleted. See: $MANIFEST_FILE" >&2
  exit 1
fi

if [ "$PLAYWRIGHT_SOURCE_PRESENT" -eq 1 ] && [ "$PLAYWRIGHT_ARCHIVE_PRESENT" -ne 1 ]; then
  echo "Archive verification failed: .playwright-cli missing from archive output." >&2
  echo "Artifacts were NOT deleted. See: $MANIFEST_FILE" >&2
  exit 1
fi

reset_local_run_artifacts

: > "$PRD_FILE"

echo "Archived Ralph run to: $ARCHIVE_DIR"
