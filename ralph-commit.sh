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
KEEP_SOURCE=false
SPRINT_BRANCH_PREFIX="ralph/sprint"
ACTIVE_PRD_MODE=""
ACTIVE_PRD_BASE_BRANCH=""

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/ralph-commit.sh [--target <branch>] [--dry-run] [--keep]

Behavior:
  1. Validates scripts/ralph/prd.json has all userStories with passes=true
  2. Archives current Ralph run via ./scripts/ralph/ralph-archive.sh
  3. Merges PRD branchName into mode-aware default target:
     - epic mode: sprint branch (ralph/sprint/<active-sprint>)
     - standalone mode: base branch (master/main)

Options:
  --target BRANCH  Explicit merge target branch (overrides mode default)
  --create-branch-if-missing  Create feature branch from current HEAD if missing
  --dry-run        Print planned actions without changing git state
  --keep           Keep source feature branch after successful merge
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
  exit 1
}

get_active_prd_epic_id() {
  if [ -f "$ACTIVE_PRD_FILE" ]; then
    jq -r 'if .mode == "epic" then (.epicId // empty) else empty end' "$ACTIVE_PRD_FILE" 2>/dev/null
    return 0
  fi
  return 1
}

get_active_prd_mode() {
  if [ -f "$ACTIVE_PRD_FILE" ]; then
    jq -r 'if (.mode | type == "string") then (.mode | ascii_downcase) else empty end' "$ACTIVE_PRD_FILE" 2>/dev/null
    return 0
  fi
  return 1
}

get_active_prd_base_branch() {
  if [ -f "$ACTIVE_PRD_FILE" ]; then
    jq -r 'if (.baseBranch | type == "string") then .baseBranch else empty end' "$ACTIVE_PRD_FILE" 2>/dev/null
    return 0
  fi
  return 1
}

infer_epic_id_from_feature_branch() {
  local feature_branch="$1"
  local epic_suffix=""
  if [[ "$feature_branch" =~ ^ralph/epic-([A-Za-z0-9-]+)$ ]]; then
    epic_suffix="${BASH_REMATCH[1]}"
  elif [[ "$feature_branch" =~ ^ralph/[^/]+/epic-([A-Za-z0-9-]+)$ ]]; then
    epic_suffix="${BASH_REMATCH[1]}"
  fi

  if [ -n "$epic_suffix" ]; then
    printf 'EPIC-%s\n' "$(printf '%s' "$epic_suffix" | tr '[:lower:]' '[:upper:]')"
    return 0
  fi

  printf ''
  return 1
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
        if (path ~ /^scripts\/ralph\/\.codex-last-message(\-iter-[0-9]+|-prd-bootstrap)?\.txt$/) next
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

reset_local_run_state() {
  rm -f "$ACTIVE_PRD_FILE"
  rm -f "$SCRIPT_DIR/.last-branch"
}

validate_archive_before_merge() {
  local archive_dir manifest_file source_playwright archived_playwright source_iter archived_iter source_transcripts archived_transcripts source_handoffs archived_handoffs
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
  source_transcripts="$(awk -F= '/^source_iteration_transcripts=/{print $2}' "$manifest_file" | tail -n 1)"
  archived_transcripts="$(awk -F= '/^archived_iteration_transcripts=/{print $2}' "$manifest_file" | tail -n 1)"
  source_handoffs="$(awk -F= '/^source_iteration_handoffs=/{print $2}' "$manifest_file" | tail -n 1)"
  archived_handoffs="$(awk -F= '/^archived_iteration_handoffs=/{print $2}' "$manifest_file" | tail -n 1)"

  if [ "$source_iter" != "$archived_iter" ]; then
    echo "Archive validation failed: iteration log count mismatch (source=$source_iter archived=$archived_iter)." >&2
    exit 1
  fi

  if [ "$source_transcripts" != "$archived_transcripts" ]; then
    echo "Archive validation failed: iteration transcript count mismatch (source=$source_transcripts archived=$archived_transcripts)." >&2
    exit 1
  fi

  if [ "$source_handoffs" != "$archived_handoffs" ]; then
    echo "Archive validation failed: iteration handoff count mismatch (source=$source_handoffs archived=$archived_handoffs)." >&2
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
          elif .status == "active" then
            .status = "ready"
          else
            .
          end
        )
    )
    | .activeEpicId = null
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
    --keep)
      KEEP_SOURCE=true
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
ACTIVE_PRD_MODE="$(get_active_prd_mode || true)"
ACTIVE_PRD_BASE_BRANCH="$(get_active_prd_base_branch || true)"

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
  if [ -n "${ACTIVE_PRD_BASE_BRANCH:-}" ]; then
    TARGET_BRANCH="$ACTIVE_PRD_BASE_BRANCH"
  else
    case "${ACTIVE_PRD_MODE:-}" in
      epic)
        ACTIVE_SPRINT="$(get_active_sprint || true)"
        if [ -z "$ACTIVE_SPRINT" ]; then
          echo "Active PRD mode is epic but no active sprint is set." >&2
          echo "Run ./scripts/ralph/ralph-sprint.sh use <sprint-name> or pass --target explicitly." >&2
          exit 1
        fi
        TARGET_BRANCH="$(sprint_branch_name "$ACTIVE_SPRINT")"
        ;;
      standalone)
        TARGET_BRANCH="$(default_base_branch)"
        ;;
      "")
        # Backward-compatible fallback for repos missing .active-prd metadata.
        ACTIVE_SPRINT="$(get_active_sprint || true)"
        if [ -n "$ACTIVE_SPRINT" ]; then
          TARGET_BRANCH="$(sprint_branch_name "$ACTIVE_SPRINT")"
        else
          TARGET_BRANCH="$(default_base_branch)"
        fi
        ;;
      *)
        echo "Unknown active PRD mode '${ACTIVE_PRD_MODE}' in $ACTIVE_PRD_FILE; falling back to legacy target selection." >&2
        ACTIVE_SPRINT="$(get_active_sprint || true)"
        if [ -n "$ACTIVE_SPRINT" ]; then
          TARGET_BRANCH="$(sprint_branch_name "$ACTIVE_SPRINT")"
        else
          TARGET_BRANCH="$(default_base_branch)"
        fi
        ;;
    esac
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

if ! git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
  if [ "$CREATE_BRANCH_IF_MISSING" = "true" ] && [ "$DRY_RUN" != "true" ]; then
    BASE_BRANCH="$(default_base_branch)"
    git branch "$TARGET_BRANCH" "$BASE_BRANCH"
    echo "Created missing target branch from $BASE_BRANCH: $TARGET_BRANCH"
  else
    echo "Target branch does not exist locally: $TARGET_BRANCH" >&2
    echo "Create it with: git branch $TARGET_BRANCH \$(git rev-parse --abbrev-ref HEAD)" >&2
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
echo "  prd mode:       ${ACTIVE_PRD_MODE:-unknown}"
echo "  prd base:       ${ACTIVE_PRD_BASE_BRANCH:-unknown}"
echo "  archive first:  yes"
if [ "$KEEP_SOURCE" = "true" ]; then
  echo "  delete source:  no (--keep)"
else
  echo "  delete source:  yes"
fi

if [ "$FEATURE_BRANCH" = "$TARGET_BRANCH" ]; then
  echo "Feature and target branches are the same ($FEATURE_BRANCH); nothing to merge." >&2
  exit 1
fi

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

if [ "${ACTIVE_PRD_MODE:-}" = "epic" ]; then
  sync_epic_status_for_completed_prd "$FEATURE_BRANCH"
else
  echo "Skipping epic status sync (mode=${ACTIVE_PRD_MODE:-unknown})."
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

enforce_transient_files_untracked

if [ "$KEEP_SOURCE" != "true" ]; then
  if git show-ref --verify --quiet "refs/heads/$FEATURE_BRANCH"; then
    if ! git branch -d "$FEATURE_BRANCH" >/dev/null 2>&1; then
      git branch -D "$FEATURE_BRANCH" >/dev/null 2>&1 || {
        echo "Merged successfully, but failed to delete source branch: $FEATURE_BRANCH" >&2
        exit 1
      }
    fi
    echo "Deleted source branch: $FEATURE_BRANCH"
  fi
else
  echo "Kept source branch: $FEATURE_BRANCH"
fi

reset_local_run_state

echo "Merge complete: $FEATURE_BRANCH -> $TARGET_BRANCH"
