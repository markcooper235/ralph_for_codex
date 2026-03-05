#!/bin/bash
# Install Ralph into a target project.
#
# Usage (from your target project root):
#   bash /path/to/ralph/install.sh
#
# Or specify a project directory:
#   bash /path/to/ralph/install.sh --project /path/to/project

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_DIR="$(pwd)"
DEST_DIR_REL="scripts/ralph"
FORCE=0
WITH_EXAMPLE_PRD=1
INSTALL_SKILLS=0
INSTALL_PROMPTS=0
SKIP_GIT_CHECK=0

usage() {
  cat <<'EOF'
Install Ralph into a target project.

Options:
  --project DIR         Project directory (default: current directory)
  --dest RELDIR         Install path relative to project (default: scripts/ralph)
  --force               Overwrite existing prd.json and progress.txt (runner files always overwritten)
  --no-example-prd      Do not create prd.json if missing
  --install-skills      Copy skills into ~/.codex/skills
  --install-prompts     Copy /command prompts to Global prompts directory
  --skip-git-check      Allow installing outside a git repo
  -h, --help            Show help

Examples:
  bash /path/to/ralph/install.sh
  bash /path/to/ralph/install.sh --project ~/code/myapp --install-skills --install-prompts
EOF
}

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT_DIR="${2:-}"; shift 2;;
    --dest)
      DEST_DIR_REL="${2:-}"; shift 2;;
    --force)
      FORCE=1; shift;;
    --no-example-prd)
      WITH_EXAMPLE_PRD=0; shift;;
    --install-skills)
      INSTALL_SKILLS=1; shift;;
      --install-prompts)
      INSTALL_PROMPTS=1; shift;;
    --skip-git-check)
      SKIP_GIT_CHECK=1; shift;;
    -h|--help)
      usage; exit 0;;
    *)
      fail "Unknown argument: $1";;
  esac
done

require_cmd cp
require_cmd chmod
require_cmd grep
require_cmd mkdir
require_cmd cat
require_cmd find

if [ -z "$PROJECT_DIR" ]; then
  fail "--project requires a directory"
fi

if [ -z "$DEST_DIR_REL" ]; then
  fail "--dest requires a relative directory"
fi

if [[ "$DEST_DIR_REL" = /* ]]; then
  fail "--dest must be a path relative to the project (got absolute path: $DEST_DIR_REL)"
fi

if [ ! -d "$PROJECT_DIR" ]; then
  fail "Project directory does not exist: $PROJECT_DIR"
fi

cd "$PROJECT_DIR"

if [ "$SKIP_GIT_CHECK" -ne 1 ]; then
  require_cmd git
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "Not inside a git repo. Re-run with --skip-git-check if intentional."
  fi
fi

mkdir -p "$DEST_DIR_REL"

copy_file() {
  local src="$1"
  local dst="$2"
  [ -f "$src" ] || fail "Missing source file: $src"
  cp "$src" "$dst"
}

copy_file "$SOURCE_DIR/ralph.sh" "$DEST_DIR_REL/ralph.sh"
copy_file "$SOURCE_DIR/ralph-prd.sh" "$DEST_DIR_REL/ralph-prd.sh"
copy_file "$SOURCE_DIR/doctor.sh" "$DEST_DIR_REL/doctor.sh"
copy_file "$SOURCE_DIR/ralph-archive.sh" "$DEST_DIR_REL/ralph-archive.sh"
copy_file "$SOURCE_DIR/ralph-cleanup.sh" "$DEST_DIR_REL/ralph-cleanup.sh"
copy_file "$SOURCE_DIR/ralph-commit.sh" "$DEST_DIR_REL/ralph-commit.sh"
copy_file "$SOURCE_DIR/ralph-epic.sh" "$DEST_DIR_REL/ralph-epic.sh"
copy_file "$SOURCE_DIR/ralph-prime.sh" "$DEST_DIR_REL/ralph-prime.sh"
copy_file "$SOURCE_DIR/ralph-sprint.sh" "$DEST_DIR_REL/ralph-sprint.sh"
copy_file "$SOURCE_DIR/ralph-sprint-commit.sh" "$DEST_DIR_REL/ralph-sprint-commit.sh"
copy_file "$SOURCE_DIR/prompt.md" "$DEST_DIR_REL/prompt.md"
copy_file "$SOURCE_DIR/prd.json.example" "$DEST_DIR_REL/prd.json.example"
copy_file "$SOURCE_DIR/epics.json.example" "$DEST_DIR_REL/epics.json.example"

chmod +x \
  "$DEST_DIR_REL/ralph.sh" \
  "$DEST_DIR_REL/ralph-prd.sh" \
  "$DEST_DIR_REL/doctor.sh" \
  "$DEST_DIR_REL/ralph-archive.sh" \
  "$DEST_DIR_REL/ralph-cleanup.sh" \
  "$DEST_DIR_REL/ralph-commit.sh" \
  "$DEST_DIR_REL/ralph-epic.sh" \
  "$DEST_DIR_REL/ralph-prime.sh" \
  "$DEST_DIR_REL/ralph-sprint.sh" \
  "$DEST_DIR_REL/ralph-sprint-commit.sh"

if [ "$WITH_EXAMPLE_PRD" -eq 1 ]; then
  if [ ! -f "$DEST_DIR_REL/prd.json" ] || [ "$FORCE" -eq 1 ]; then
    cat > "$DEST_DIR_REL/prd.json" <<'JSON'
{
  "project": "YourProject",
  "branchName": "ralph/smoke",
  "description": "Smoke test - verify Ralph + Codex loop works end-to-end",
  "userStories": [
    {
      "id": "US-001",
      "title": "Create smoke marker file",
      "description": "As a developer, I want a smoke marker file so I can confirm Ralph executed.",
      "acceptanceCriteria": [
        "Create a new file at repo root named RALPH_SMOKE.txt with exactly: ok\\n",
        "Commit the change",
        "Update scripts/ralph/prd.json to set passes: true for US-001",
        "Append a short entry to scripts/ralph/progress.txt",
        "Typecheck passes"
      ],
      "priority": 1,
      "passes": false,
      "notes": "If this repo has no typecheck, treat this as: no build errors, and keep git status clean after commit."
    }
  ]
}
JSON
  fi
fi

if [ ! -f "$DEST_DIR_REL/progress.txt" ] || [ "$FORCE" -eq 1 ]; then
  cat > "$DEST_DIR_REL/progress.txt" <<EOF
# Ralph Progress Log
Started: $(date)
---
EOF
fi

# Sprint-aware bootstrap directories and default active sprint.
mkdir -p \
  "$DEST_DIR_REL/sprints/sprint-1" \
  "$DEST_DIR_REL/tasks/sprint-1" \
  "$DEST_DIR_REL/tasks/prds" \
  "$DEST_DIR_REL/tasks/archive/sprint-1" \
  "$DEST_DIR_REL/tasks/archive/prds"

if [ ! -f "$DEST_DIR_REL/sprints/sprint-1/epics.json" ] || [ "$FORCE" -eq 1 ]; then
  cp "$DEST_DIR_REL/epics.json.example" "$DEST_DIR_REL/sprints/sprint-1/epics.json"
fi

if [ ! -f "$DEST_DIR_REL/.active-sprint" ] || [ "$FORCE" -eq 1 ]; then
  printf 'sprint-1\n' > "$DEST_DIR_REL/.active-sprint"
fi

# Keep generated files out of git noise.
GITIGNORE_SOURCE="$SOURCE_DIR/.gitignore"
GITIGNORE_DEST=".gitignore"
[ -f "$GITIGNORE_SOURCE" ] || fail "Missing source file: $GITIGNORE_SOURCE"

if [ ! -f "$GITIGNORE_DEST" ]; then
  copy_file "$GITIGNORE_SOURCE" "$GITIGNORE_DEST"
else
  while IFS= read -r line || [ -n "$line" ]; do
    if ! grep -qxF "$line" "$GITIGNORE_DEST"; then
      printf "%s\n" "$line" >> "$GITIGNORE_DEST"
    fi
  done < "$GITIGNORE_SOURCE"
fi

if [ "$INSTALL_SKILLS" -eq 1 ]; then
  if [ -z "${HOME:-}" ]; then
    fail "HOME is not set; cannot install skills"
  fi
  CODEX_SKILLS_DIR="${HOME}/.codex/skills"
  mkdir -p "$CODEX_SKILLS_DIR"
  [ -d "$SOURCE_DIR/skills" ] || fail "Missing skills directory: $SOURCE_DIR/skills"

  while IFS= read -r -d '' dir; do
    name="$(basename "$dir")"
    [ -f "$dir/SKILL.md" ] || continue
    cp -r "$dir" "$CODEX_SKILLS_DIR/"
    echo "Installed Codex skill: $name"
  done < <(find "$SOURCE_DIR/skills" -mindepth 1 -maxdepth 1 -type d -print0)
fi

if [ "$INSTALL_PROMPTS" -eq 1 ]; then
  if [ -z "${HOME:-}" ]; then
    fail "HOME is not set; cannot install prompts"
  fi
  CODEX_GLOBAL_PROMPTS_DIR="${HOME}/.codex/prompts"
  mkdir -p "$CODEX_GLOBAL_PROMPTS_DIR"
  [ -d "$SOURCE_DIR/prompts" ] || fail "Missing command_prompts directory: $SOURCE_DIR/prompts"

  while IFS= read -r -d '' file; do
    name="$(basename "$file")"
    [ -f "$file" ] || continue
    cp "$file" "$CODEX_GLOBAL_PROMPTS_DIR/"
    echo "Installed Codex prompt: $name"
  done < <(find "$SOURCE_DIR/prompts" -type f -print0)
fi

echo "Installed Ralph into: $PROJECT_DIR/$DEST_DIR_REL"
echo "Next:"
echo "  1) ./$DEST_DIR_REL/doctor.sh"
echo "  2) ./$DEST_DIR_REL/ralph-sprint.sh status"
echo "  3) ./$DEST_DIR_REL/ralph-epic.sh list"
echo "  4) ./$DEST_DIR_REL/ralph-prd.sh  (standalone flow) OR ./$DEST_DIR_REL/ralph-prime.sh  (epic flow)"
echo "  5) ./$DEST_DIR_REL/ralph.sh 10"
echo "  6) ./$DEST_DIR_REL/ralph-commit.sh  (merge epic -> sprint branch)"
echo "  7) ./$DEST_DIR_REL/ralph-sprint-commit.sh  (close sprint: merge sprint -> master/main)"
