#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
SPRINTS_DIR="$SCRIPT_DIR/sprints"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
ACTIVE_PRD_FILE="$SCRIPT_DIR/.active-prd"
EPICS_FILE=""
ARCHIVE_TRACK_PATH="$SCRIPT_DIR/tasks/archive"
ARCHIVE_CMD="$SCRIPT_DIR/ralph-archive.sh"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PLAYWRIGHT_CLI_DIR="$WORKSPACE_ROOT/.playwright-cli"
TARGET_BRANCH=""
DRY_RUN=false
CREATE_BRANCH_IF_MISSING=false

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/ralph-commit.sh [--target master|main] [--dry-run]

Behavior:
  1. Validates scripts/ralph/prd.json has all userStories with passes=true
  2. Archives current Ralph run via ./scripts/ralph/ralph-archive.sh
  3. Merges PRD branchName into target branch (master preferred, else main)

Options:
  --target BRANCH  Explicit merge target branch
  --create-branch-if-missing  Create feature branch from current HEAD if missing
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

get_active_sprint() {
  if [ -f "$ACTIVE_SPRINT_FILE" ]; then
    awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE"
    return 0
  fi
  return 1
}

resolve_epics_file() {
  local active_sprint
  active_sprint="$(get_active_sprint || true)"
  if [ -z "$active_sprint" ]; then
    EPICS_FILE=""
    return 0
  fi
  EPICS_FILE="$SPRINTS_DIR/$active_sprint/epics.json"
}

get_active_prd_epic_id() {
  if [ -f "$ACTIVE_PRD_FILE" ]; then
    jq -r 'if .mode == "epic" then (.epicId // empty) else empty end' "$ACTIVE_PRD_FILE" 2>/dev/null
    return 0
  fi
  return 1
}

infer_epic_id_from_feature_branch() {
  local feature_branch="$1"
  if [[ "$feature_branch" =~ ^ralph/epic-([0-9]+)$ ]]; then
    printf 'EPIC-%03d\n' "$((10#${BASH_REMATCH[1]}))"
    return 0
  fi

  printf ''
  return 1
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
  archive_status="$(git status --porcelain -- "$ARCHIVE_TRACK_PATH")"
  if [ -z "$archive_status" ]; then
    return 0
  fi

  git add -A "$ARCHIVE_TRACK_PATH"
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

enforce_transient_files_untracked() {
  local tracked
  tracked="$(git ls-files -- "$PRD_FILE" "$SCRIPT_DIR/progress.txt" || true)"
  if [ -z "$tracked" ]; then
    return 0
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    git rm --cached -- "$path" >/dev/null 2>&1 || true
  done <<< "$tracked"

  if ! git diff --cached --quiet; then
    git commit -m "chore(ralph): keep transient Ralph files untracked"
    echo "Removed transient Ralph files from git tracking on target branch."
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

sync_epic_status_for_completed_prd() {
  local feature_branch="$1"
  local epic_id epic_status tmp_file

  if [ -z "${EPICS_FILE:-}" ] || [ ! -f "$EPICS_FILE" ] || ! jq -e '.epics and (.epics | type == "array")' "$EPICS_FILE" >/dev/null 2>&1; then
    echo "Skipping epic status sync: missing or invalid $EPICS_FILE"
    return 0
  fi

  epic_id="$(infer_epic_id_from_feature_branch "$feature_branch" || true)"
  if [ -z "$epic_id" ]; then
    epic_id="$(get_active_prd_epic_id || true)"
  fi

  if [ -z "$epic_id" ]; then
    echo "Skipping epic status sync: unable to infer epic ID from $feature_branch"
    return 0
  fi

  if ! jq -e --arg id "$epic_id" '.epics[] | select(.id == $id)' "$EPICS_FILE" >/dev/null 2>&1; then
    echo "Skipping epic status sync: $epic_id not found in $EPICS_FILE"
    return 0
  fi

  epic_status="$(jq -r --arg id "$epic_id" '.epics[] | select(.id == $id) | (.status // "")' "$EPICS_FILE")"
  case "$epic_status" in
    done)
      echo "Epic already done: $epic_id"
      return 0
      ;;
    abandoned|aborted)
      echo "Epic is $epic_status: $epic_id (leaving status unchanged)"
      return 0
      ;;
  esac

  tmp_file="$(mktemp)"
  jq --arg id "$epic_id" '
    .epics = (
      .epics
      | map(
          if .id == $id then
            .status = "done"
          else
            .
          end
        )
    )
    | if .activeEpicId == $id then .activeEpicId = null else . end
  ' "$EPICS_FILE" > "$tmp_file"
  mv "$tmp_file" "$EPICS_FILE"

  if ! git diff --quiet -- "$EPICS_FILE"; then
    git add "$EPICS_FILE"
    git commit -m "chore(ralph): mark $epic_id done after PRD completion"
    echo "Epic status synced: $epic_id -> done"
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
    --create-branch-if-missing)
      CREATE_BRANCH_IF_MISSING=true
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
resolve_epics_file

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

CURRENT_BRANCH="$(git branch --show-current)"

if ! git show-ref --verify --quiet "refs/heads/$FEATURE_BRANCH"; then
  if [ "$CREATE_BRANCH_IF_MISSING" = "true" ] && [ "$DRY_RUN" != "true" ]; then
    git checkout -b "$FEATURE_BRANCH"
    echo "Created missing feature branch from current HEAD: $FEATURE_BRANCH"
    CURRENT_BRANCH="$FEATURE_BRANCH"
  else
    echo "Feature branch does not exist locally: $FEATURE_BRANCH" >&2
    echo "Create it with: git checkout -b $FEATURE_BRANCH" >&2
    echo "Or rerun with --create-branch-if-missing." >&2
    exit 1
  fi
fi

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

sync_epic_status_for_completed_prd "$FEATURE_BRANCH"

git checkout "$TARGET_BRANCH"
if ! git -c merge.renames=false merge --no-ff "$FEATURE_BRANCH" -m "merge: Ralph run $FEATURE_BRANCH"; then
  resolve_ralph_conflicts_or_fail
  if [ -n "$(git diff --name-only --diff-filter=U || true)" ]; then
    echo "Merge failed with unresolved conflicts." >&2
    exit 1
  fi
  git commit --no-edit
fi

enforce_transient_files_untracked

echo "Merge complete: $FEATURE_BRANCH -> $TARGET_BRANCH"
