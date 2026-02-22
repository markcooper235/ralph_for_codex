#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"
ARCHIVE_ROOT="$SCRIPT_DIR/archive"
WORKSPACE_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || cd "$SCRIPT_DIR/../.." && pwd)"
PLAYWRIGHT_CLI_DIR="$WORKSPACE_ROOT/.playwright-cli"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

ensure_clean_worktree() {
  if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
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

require_cmd jq
require_cmd git
require_cmd sed
require_cmd tr

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ralph-archive must be run inside a git repository." >&2
  exit 1
fi

ensure_clean_worktree

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

ITER_SOURCE_COUNT=0
for iter_log in "$SCRIPT_DIR"/.codex-last-message-iter-*.txt; do
  [ -f "$iter_log" ] || continue
  ITER_SOURCE_COUNT=$((ITER_SOURCE_COUNT + 1))
done

PLAYWRIGHT_SOURCE_PRESENT=0
[ -d "$PLAYWRIGHT_CLI_DIR" ] && PLAYWRIGHT_SOURCE_PRESENT=1

[ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_DIR/"
[ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_DIR/"
[ -f "$SCRIPT_DIR/.codex-last-message.txt" ] && cp "$SCRIPT_DIR/.codex-last-message.txt" "$ARCHIVE_DIR/"

for iter_log in "$SCRIPT_DIR"/.codex-last-message-iter-*.txt; do
  [ -f "$iter_log" ] || continue
  cp "$iter_log" "$ARCHIVE_DIR/"
done
[ -d "$PLAYWRIGHT_CLI_DIR" ] && cp -a "$PLAYWRIGHT_CLI_DIR" "$ARCHIVE_DIR/"

ITER_ARCHIVE_COUNT=$(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name '.codex-last-message-iter-*.txt' | wc -l | tr -d '[:space:]')
PLAYWRIGHT_ARCHIVE_PRESENT=0
[ -d "$ARCHIVE_DIR/.playwright-cli" ] && PLAYWRIGHT_ARCHIVE_PRESENT=1

{
  echo "archive_time=$(date -Iseconds)"
  echo "source_branch=$BRANCH_NAME"
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

: > "$PRD_FILE"

echo "Archived Ralph run to: $ARCHIVE_DIR"
