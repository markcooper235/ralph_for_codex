#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
ARCHIVE_CMD="$SCRIPT_DIR/ralph-archive.sh"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PLAYWRIGHT_CLI_DIR="$WORKSPACE_ROOT/.playwright-cli"
TARGET_BRANCH=""
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/ralph-commit.sh [--target master|main] [--dry-run]

Behavior:
  1. Validates scripts/ralph/prd.json has all userStories with passes=true
  2. Archives current Ralph run via ./scripts/ralph/ralph-archive.sh
  3. Merges PRD branchName into target branch (master preferred, else main)

Options:
  --target BRANCH  Explicit merge target branch
  --dry-run        Print planned actions without changing git state
  -h, --help       Show this help
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

ensure_clean_worktree() {
  if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
    echo "Working tree is not clean. Commit or stash all changes before running ralph-commit." >&2
    echo "Hint: run 'git status --short' to review pending changes." >&2
    exit 1
  fi
}

commit_archive_changes() {
  local archive_status
  archive_status="$(git status --porcelain -- scripts/ralph/archive)"
  if [ -z "$archive_status" ]; then
    return 0
  fi

  git add -A scripts/ralph/archive
  if git diff --cached --quiet; then
    return 0
  fi

  git commit -m "chore(ralph): archive run artifacts before merge"
}

resolve_ralph_conflicts_or_fail() {
  local conflicts path unresolved_non_ralph
  conflicts="$(git diff --name-only --diff-filter=U || true)"
  [ -z "$conflicts" ] && return 0

  unresolved_non_ralph=0
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    case "$path" in
      scripts/ralph/*)
        # During merge into target branch, "theirs" is the feature branch.
        # Prefer feature branch content for Ralph workflow files/artifacts.
        git checkout --theirs -- "$path" >/dev/null 2>&1 || true
        git add -- "$path" >/dev/null 2>&1 || true
        ;;
      *)
        unresolved_non_ralph=1
        ;;
    esac
  done <<< "$conflicts"

  if [ "$unresolved_non_ralph" -eq 1 ]; then
    echo "Merge failed with unresolved non-Ralph conflicts:" >&2
    git diff --name-only --diff-filter=U >&2 || true
    exit 1
  fi
}

validate_archive_before_merge() {
  local archive_dir manifest_file source_playwright archived_playwright source_iter archived_iter
  archive_dir="$1"
  manifest_file="$archive_dir/archive-manifest.txt"

  if [ ! -f "$manifest_file" ]; then
    echo "Archive validation failed: missing manifest file at $manifest_file" >&2
    exit 1
  fi

  source_playwright="$(awk -F= '/^source_playwright_cli_present=/{print $2}' "$manifest_file" | tail -n 1)"
  archived_playwright="$(awk -F= '/^archived_playwright_cli_present=/{print $2}' "$manifest_file" | tail -n 1)"
  source_iter="$(awk -F= '/^source_iter_logs=/{print $2}' "$manifest_file" | tail -n 1)"
  archived_iter="$(awk -F= '/^archived_iter_logs=/{print $2}' "$manifest_file" | tail -n 1)"

  if [ "$source_iter" != "$archived_iter" ]; then
    echo "Archive validation failed: iteration log count mismatch (source=$source_iter archived=$archived_iter)." >&2
    exit 1
  fi

  if [ "$source_playwright" = "1" ] && [ "$archived_playwright" != "1" ]; then
    echo "Archive validation failed: .playwright-cli was present but not archived." >&2
    exit 1
  fi

  if [ "$source_playwright" = "1" ] && [ -d "$PLAYWRIGHT_CLI_DIR" ]; then
    echo "Archive validation failed: .playwright-cli still exists after archive." >&2
    exit 1
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      TARGET_BRANCH="${2:-}"
      if [ -z "$TARGET_BRANCH" ]; then
        echo "--target requires a branch name" >&2
        exit 1
      fi
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd git
require_cmd jq
require_cmd awk
require_cmd sed

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Must be run inside a git repository." >&2
  exit 1
fi

if [ ! -f "$PRD_FILE" ] || ! jq -e '.' "$PRD_FILE" >/dev/null 2>&1; then
  echo "Missing or invalid PRD file: $PRD_FILE" >&2
  exit 1
fi

FEATURE_BRANCH="$(jq -r '.branchName // empty' "$PRD_FILE")"
if [ -z "$FEATURE_BRANCH" ]; then
  echo "PRD missing branchName in $PRD_FILE" >&2
  exit 1
fi

if ! jq -e '(.userStories | length) > 0 and all(.userStories[]; .passes == true)' "$PRD_FILE" >/dev/null 2>&1; then
  echo "Not all stories are marked passes=true in $PRD_FILE" >&2
  exit 1
fi

if [ -z "$TARGET_BRANCH" ]; then
  if git show-ref --verify --quiet refs/heads/master; then
    TARGET_BRANCH="master"
  elif git show-ref --verify --quiet refs/heads/main; then
    TARGET_BRANCH="main"
  else
    echo "Could not find target branch (master or main)." >&2
    exit 1
  fi
fi

if ! git show-ref --verify --quiet "refs/heads/$FEATURE_BRANCH"; then
  echo "Feature branch does not exist locally: $FEATURE_BRANCH" >&2
  exit 1
fi

CURRENT_BRANCH="$(git branch --show-current)"

if [ "$DRY_RUN" != "true" ]; then
  ensure_clean_worktree
fi

if [ ! -x "$ARCHIVE_CMD" ]; then
  echo "Missing archive command: $ARCHIVE_CMD" >&2
  exit 1
fi

echo "Ralph commit plan:"
echo "  feature branch: $FEATURE_BRANCH"
echo "  target branch:  $TARGET_BRANCH"
echo "  current branch: $CURRENT_BRANCH"
echo "  archive first:  yes"

if [ "$DRY_RUN" = "true" ]; then
  echo ""
  echo "Dry run: no changes made."
  exit 0
fi

ARCHIVE_OUTPUT="$("$ARCHIVE_CMD" 2>&1)"
echo "$ARCHIVE_OUTPUT"
ARCHIVE_DIR="$(printf '%s\n' "$ARCHIVE_OUTPUT" | sed -n 's/^Archived Ralph run to: //p' | tail -n 1)"
if [ -z "$ARCHIVE_DIR" ]; then
  echo "Archive validation failed: could not determine archive destination from ralph-archive output." >&2
  exit 1
fi
validate_archive_before_merge "$ARCHIVE_DIR"
commit_archive_changes

if git ls-files --error-unmatch "$PRD_FILE" >/dev/null 2>&1; then
  git checkout -- "$PRD_FILE"
fi

if [ "$CURRENT_BRANCH" != "$FEATURE_BRANCH" ]; then
  git checkout "$FEATURE_BRANCH"
fi

git checkout "$TARGET_BRANCH"
if ! git -c merge.renames=false merge --no-ff "$FEATURE_BRANCH" -m "merge: Ralph run $FEATURE_BRANCH"; then
  resolve_ralph_conflicts_or_fail
  if [ -n "$(git diff --name-only --diff-filter=U || true)" ]; then
    echo "Merge failed with unresolved conflicts." >&2
    exit 1
  fi
  git commit --no-edit
fi

echo "Merge complete: $FEATURE_BRANCH -> $TARGET_BRANCH"
