#!/bin/bash
# e2e-calendar.sh — Full end-to-end Calendar + Todo app smoke test
#
# Exercises the complete Ralph lifecycle for two real framework projects:
#
#   nextjs-calendar  — Real Next.js project (create-next-app) with Jest.
#                      Domain services in lib/. Tests in __tests__/.
#   angular-calendar — Real Angular project (ng new) with Jest via ts-jest.
#                      Services in src/app/services/. Tests as *.spec.ts.
#
# Full lifecycle under test:
#   install.sh → doctor.sh → ralph-sprint.sh create → ralph-story.sh add →
#   (story.json: hand-written default | Codex-generated --generated) →
#   ralph-story.sh health → ralph.sh → ralph-status.sh →
#   ralph-sprint-commit.sh → ralph-verify.sh
#
# Each project runs one sprint with 4 stories:
#   S-001: Core types / data models
#   S-002: Calendar service                 (depends on S-001)
#   S-003: Todo service                     (depends on S-001)
#   S-004: Barrel export + integration test (depends on S-001, S-002, S-003)
#
# Usage:
#   ./scripts/smoke/e2e-calendar.sh [--keep] [--max-retries N] [--generated]
#
# Flags:
#   --keep          Keep work directory on success (always kept on failure)
#   --max-retries N Retry count per task (default: 2)
#   --generated     Use ralph-story.sh generate for story.json instead of
#                   hand-written files — exercises the full story generation
#                   pipeline (adds ~8 Codex sessions total)
#
# NOTE: story-level depends_on is patched into stories.json via jq after
# ralph-story.sh add, because add does not yet accept --depends-on.
# This is a known framework gap.

set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

# macOS does not ship 'timeout'; provide a portable fallback
if ! command -v timeout >/dev/null 2>&1; then
  if command -v gtimeout >/dev/null 2>&1; then
    timeout() { gtimeout "$@"; }
  else
    timeout() { local t=$1; shift; perl -e 'alarm shift @ARGV; exec @ARGV' "$t" "$@"; }
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/assert.sh"

KEEP=0
MAX_RETRIES=2
GENERATED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)         KEEP=1; shift ;;
    --max-retries)  MAX_RETRIES="${2:-2}"; shift 2 ;;
    --generated)    GENERATED=1; shift ;;
    -h|--help)
      sed -n '/^# Usage/,/^[^#]/p' "$0" | head -n -1 | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

WORK_DIR="$(mktemp -d /tmp/ralph-calendar-smoke.XXXXXX)"
LOG_DIR="$WORK_DIR/logs"
mkdir -p "$LOG_DIR"

NEXTJS_DIR="$WORK_DIR/nextjs-calendar"
ANGULAR_DIR="$WORK_DIR/angular-calendar"

# ── Cleanup ────────────────────────────────────────────────────────────────────

cleanup() {
  local code=$?
  if [ "$KEEP" -eq 1 ] || [ "$code" -ne 0 ]; then
    echo ""
    echo "[smoke] work dir retained for inspection: $WORK_DIR"
    echo "  nextjs:   $NEXTJS_DIR"
    echo "  angular:  $ANGULAR_DIR"
    echo "  logs:     $LOG_DIR"
    return
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ── Helpers ────────────────────────────────────────────────────────────────────

log()  { echo "[smoke] $*"; }
fail() { echo "[smoke] FAIL: $*" >&2; exit 1; }

# Commit any staged or unstaged changes (used for framework baseline commits)
commit_baseline() {
  local repo="$1"
  local msg="$2"
  (
    cd "$repo"
    git add -A
    if ! git diff --cached --quiet; then
      git commit -m "$msg" >/dev/null
    fi
  )
}

# ── doctor_check ───────────────────────────────────────────────────────────────
# Run doctor.sh after install. Accepts a missing 'specify' CLI (not used in the
# smoke test), but fails on any other diagnostic error (missing codex, jq, etc).

doctor_check() {
  local proj_dir="$1"
  local proj_label="$2"
  local dlog="$LOG_DIR/${proj_label}-doctor.log"
  log "  Running doctor.sh..."
  if (cd "$proj_dir/scripts/ralph" && CODEX_BIN=codex ./doctor.sh) > "$dlog" 2>&1; then
    log "  doctor.sh PASS"
  elif grep -q "specify.*CLI not found\|specify.*not found" "$dlog" 2>/dev/null; then
    log "  doctor.sh WARN: specify CLI not available (expected — not used in smoke test)"
  else
    cat "$dlog" >&2
    fail "doctor.sh failed for $proj_label — see $dlog"
  fi
}

# ── generate_stories ───────────────────────────────────────────────────────────
# Call ralph-story.sh generate for all 4 stories in parallel.
# Codex generates story.json task plans from the story specs in stories.json.
# All 4 run in parallel since no done_notes exist yet (dep context is empty).

generate_stories() {
  local proj_dir="$1"
  local proj_label="$2"
  local ralph_dir="$proj_dir/scripts/ralph"

  log "  Generating story.json files via ralph-story.sh generate (parallel)..."

  local sids=(S-001 S-002 S-003 S-004)
  local pids=() glogs=()

  for sid in "${sids[@]}"; do
    local glog="$LOG_DIR/${proj_label}-generate-${sid}.log"
    glogs+=("$glog")
    ( cd "$ralph_dir" && CODEX_BIN=codex ./ralph-story.sh generate "$sid" ) \
      > "$glog" 2>&1 &
    pids+=($!)
  done

  local failed=0 i=0
  for pid in "${pids[@]}"; do
    local sid="${sids[$i]}" glog="${glogs[$i]}"
    if wait "$pid"; then
      local story_path="$ralph_dir/sprints/sprint-1/stories/$sid/story.json"
      if [ ! -f "$story_path" ]; then
        log "  FAIL: generate $sid wrote no story.json"
        failed=$((failed + 1))
      elif ! jq -e '.tasks | length > 0' "$story_path" >/dev/null 2>&1; then
        log "  FAIL: generate $sid produced story.json with no tasks"
        failed=$((failed + 1))
      else
        log "  generated $sid ($(jq '.tasks | length' "$story_path") tasks)"
      fi
    else
      log "  FAIL: generate $sid — see $glog"
      failed=$((failed + 1))
    fi
    i=$((i + 1))
  done

  [ "$failed" -eq 0 ] \
    || fail "Story generation failed for $proj_label ($failed of ${#sids[@]} stories)"
}

# ── run_sprint_commit ──────────────────────────────────────────────────────────
# Run ralph-sprint-commit.sh for a project. Asserts sprint is closed and
# .active-sprint is cleared after the commit.

run_sprint_commit() {
  local proj_dir="$1"
  local proj_label="$2"
  local clog="$LOG_DIR/${proj_label}-sprint-commit.log"

  log "  Running ralph-sprint-commit.sh for $proj_label..."
  if ! (cd "$proj_dir/scripts/ralph" && ./ralph-sprint-commit.sh) > "$clog" 2>&1; then
    cat "$clog" >&2
    fail "ralph-sprint-commit.sh failed for $proj_label — see $clog"
  fi

  # Assert sprint is now closed in stories.json
  local stories_file="$proj_dir/scripts/ralph/sprints/sprint-1/stories.json"
  local sprint_status
  sprint_status="$(jq -r '.status // "unknown"' "$stories_file" 2>/dev/null || echo "unknown")"
  [ "$sprint_status" = "closed" ] \
    || fail "$proj_label sprint-commit: expected stories.json status=closed, got '$sprint_status'"

  # Assert .active-sprint has been cleared
  local active_file="$proj_dir/scripts/ralph/.active-sprint"
  if [ -f "$active_file" ] && [ -n "$(cat "$active_file")" ]; then
    fail "$proj_label sprint-commit: .active-sprint was not cleared after commit"
  fi

  log "  sprint-commit PASS (status=closed, active-sprint cleared)"
}

# ── Validation helpers ─────────────────────────────────────────────────────────

validate_story() {
  local story_file="$1"
  local story_id
  story_id="$(jq -r '.storyId' "$story_file")"

  # Required top-level fields
  jq -e '.storyId and .title and .tasks and .sprint' "$story_file" > /dev/null \
    || fail "[$story_id] story.json missing required top-level fields"

  # Each task has checks
  local bad_tasks
  bad_tasks="$(jq -r '.tasks[] | select((.checks | length) == 0) | .id' "$story_file")"
  [ -z "$bad_tasks" ] || fail "[$story_id] tasks with no checks: $bad_tasks"

  # No empty check strings
  local empty_checks
  empty_checks="$(jq -r '.tasks[] | .id as $t | .checks[] | select(length == 0) | $t' "$story_file")"
  [ -z "$empty_checks" ] || fail "[$story_id] empty check strings in tasks: $empty_checks"

  # depends_on T-IDs exist in the same story
  local all_ids
  all_ids="$(jq -r '.tasks[].id' "$story_file")"
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    echo "$all_ids" | grep -qxF "$dep" \
      || fail "[$story_id] task depends_on '$dep' which does not exist in story"
  done < <(jq -r '.tasks[].depends_on[]?' "$story_file")
}

validate_sprint() {
  local ralph_dir="$1"
  local sprint="$2"
  local stories_file="$ralph_dir/sprints/$sprint/stories.json"

  [ -f "$stories_file" ] || fail "stories.json not found: $stories_file"
  jq -e '.' "$stories_file" > /dev/null || fail "stories.json is invalid JSON"

  # Validate story-level depends_on references exist
  local all_story_ids
  all_story_ids="$(jq -r '.stories[].id' "$stories_file")"
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    echo "$all_story_ids" | grep -qxF "$dep" \
      || fail "story depends_on '$dep' which is not in stories.json"
  done < <(jq -r '.stories[].depends_on[]?' "$stories_file" 2>/dev/null)

  # Validate each story.json
  while IFS= read -r story_path; do
    [ -z "$story_path" ] && continue
    local abs_path
    abs_path="$(git -C "$(dirname "$ralph_dir")" rev-parse --show-toplevel 2>/dev/null || dirname "$ralph_dir")"
    abs_path="$abs_path/$story_path"
    [ -f "$abs_path" ] || abs_path="$story_path"
    [ -f "$abs_path" ] || fail "story.json not found: $story_path"
    validate_story "$abs_path"
    log "  validated: $(basename "$(dirname "$abs_path")")/story.json"
  done < <(jq -r '.stories[].story_path' "$stories_file")
}

# ── Execution helpers ──────────────────────────────────────────────────────────

run_sprint() {
  local proj_dir="$1"
  local proj_label="$2"
  local log_file="$LOG_DIR/${proj_label}-sprint.log"

  log "Running sprint for $proj_label..."
  (
    cd "$proj_dir/scripts/ralph"
    timeout 2700 env CODEX_BIN=codex \
      ./ralph.sh --max-retries "$MAX_RETRIES" --continue-on-failure \
      2>&1
  ) | tee "$log_file"
  return "${PIPESTATUS[0]}"
}

# ── Report helpers ─────────────────────────────────────────────────────────────

extract_story_status() {
  local log="$1"
  grep -E "=== Story S-[0-9]+ (COMPLETE|some tasks)" "$log" 2>/dev/null || true
}

extract_structural_failures() {
  local log="$1"
  grep "STRUCTURAL FAILURE" "$log" 2>/dev/null || true
}

extract_task_failures() {
  local log="$1"
  grep "FAILED after.*attempts" "$log" 2>/dev/null || true
}

count_stories_done() {
  local stories_file="$1"
  jq '[.stories[] | select(.status == "done")] | length' "$stories_file" 2>/dev/null || echo 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  PROJECT 1: nextjs-calendar
#  Real Next.js project via create-next-app. Domain services in lib/.
#  Tests in __tests__/ using Jest + ts-jest.
# ══════════════════════════════════════════════════════════════════════════════

log "=== Setting up nextjs-calendar ==="

cd "$WORK_DIR"
log "  Running create-next-app..."
npx create-next-app@latest nextjs-calendar \
  --typescript \
  --no-tailwind \
  --no-eslint \
  --app \
  --no-src-dir \
  --use-npm \
  --yes \
  --disable-git \
  > "$LOG_DIR/nextjs-create.log" 2>&1 \
  || fail "create-next-app failed — see $LOG_DIR/nextjs-create.log"

cd "$NEXTJS_DIR"
git init -b main >/dev/null
git config user.name "Ralph Smoke"
git config user.email "ralph-smoke@example.com"

log "  Adding Jest..."
npm install --save-dev jest @types/jest ts-jest jest-environment-node --silent \
  >> "$LOG_DIR/nextjs-create.log" 2>&1

npm pkg set scripts.test="jest"
npm pkg set scripts.typecheck="tsc --noEmit"

cat > jest.config.ts <<'TS'
import type { Config } from 'jest'

const config: Config = {
  transform: {
    '^.+\\.tsx?$': ['ts-jest', {
      tsconfig: {
        module: 'commonjs',
        moduleResolution: 'node',
      },
    }],
  },
  testEnvironment: 'node',
  moduleNameMapper: {
    '^@/(.*)$': '<rootDir>/$1',
  },
  testMatch: ['**/__tests__/**/*.test.ts'],
  testPathIgnorePatterns: ['/node_modules/', '/.next/'],
}

export default config
TS

mkdir -p lib __tests__

cat > lib/index.ts <<'TS'
export const APP_NAME = "nextjs-calendar"
export const APP_VERSION = "0.1.0"
TS

cat > __tests__/baseline.test.ts <<'TS'
import { APP_NAME, APP_VERSION } from '../lib/index'

describe('baseline', () => {
  it('exports APP_NAME', () => {
    expect(APP_NAME).toBe('nextjs-calendar')
  })
  it('exports APP_VERSION', () => {
    expect(typeof APP_VERSION).toBe('string')
  })
})
TS

git add .
git reset -- .next >/dev/null 2>&1 || true
git commit -m "chore: init nextjs-calendar" >/dev/null

log "  installing ralph framework..."
HOME="$WORK_DIR/home-nextjs" "$REPO_ROOT/install.sh" \
  --project "$NEXTJS_DIR" > "$LOG_DIR/install-nextjs.log" 2>&1
assert_file_exists "$NEXTJS_DIR/scripts/ralph/ralph.sh"
assert_file_exists "$NEXTJS_DIR/scripts/ralph/ralph-task.sh"
assert_file_exists "$NEXTJS_DIR/scripts/ralph/ralph-story.sh"
assert_file_exists "$NEXTJS_DIR/scripts/ralph/ralph-sprint.sh"
assert_file_exists "$NEXTJS_DIR/scripts/ralph/ralph-sprint-commit.sh"
assert_file_exists "$NEXTJS_DIR/scripts/ralph/doctor.sh"

# ── NextJS sprint scaffold ─────────────────────────────────────────────────────

(
  cd "$NEXTJS_DIR/scripts/ralph"

  ./ralph-sprint.sh create sprint-1 > "$LOG_DIR/nextjs-sprint-create.log" 2>&1
  assert_contains "$LOG_DIR/nextjs-sprint-create.log" "Created sprint: sprint-1"

  ./ralph-story.sh add --title "Core types and interfaces" \
    --goal "Define all TypeScript types for the calendar and todo domain." \
    --prompt-context "Create lib/types.ts with CalendarEvent, Todo, Category interfaces and a Priority type." \
    > "$LOG_DIR/nextjs-story-add-S-001.log" 2>&1

  ./ralph-story.sh add --title "Calendar service" \
    --goal "Implement a CalendarStore class with add/remove/query operations." \
    --prompt-context "Create lib/calendarService.ts importing CalendarEvent from types." \
    > "$LOG_DIR/nextjs-story-add-S-002.log" 2>&1

  ./ralph-story.sh add --title "Todo service" \
    --goal "Implement a TodoStore class with CRUD and priority filtering." \
    --prompt-context "Create lib/todoService.ts importing Todo, Priority from types." \
    > "$LOG_DIR/nextjs-story-add-S-003.log" 2>&1

  ./ralph-story.sh add --title "Barrel export and integration" \
    --goal "Wire all modules through lib/index.ts and add cross-module integration test." \
    --prompt-context "Update lib/index.ts to re-export calendarService, todoService, types. Add __tests__/integration.test.ts." \
    > "$LOG_DIR/nextjs-story-add-S-004.log" 2>&1

  # Patch story-level depends_on into stories.json.
  # ralph-story.sh add does not yet accept --depends-on (known framework gap).
  _sf="sprints/sprint-1/stories.json"
  _tmp="$(mktemp)"
  jq '
    .stories = [.stories[] |
      if   .id == "S-002" then .depends_on = ["S-001"]
      elif .id == "S-003" then .depends_on = ["S-001"]
      elif .id == "S-004" then .depends_on = ["S-001", "S-002", "S-003"]
      else . end
    ]
  ' "$_sf" > "$_tmp" && mv "$_tmp" "$_sf"
)

# ── NextJS doctor check ────────────────────────────────────────────────────────

doctor_check "$NEXTJS_DIR" "nextjs"

# ── NextJS story.json definitions ─────────────────────────────────────────────
# --generated: let ralph-story.sh generate (Codex) produce story.json files
# default:     use hand-written task plans for deterministic fast execution

if [ "$GENERATED" -eq 1 ]; then
  generate_stories "$NEXTJS_DIR" "nextjs"
else

mkdir -p "$NEXTJS_DIR/scripts/ralph/sprints/sprint-1/stories/S-001"
cat > "$NEXTJS_DIR/scripts/ralph/sprints/sprint-1/stories/S-001/story.json" <<'STORYJSON'
{
  "version": 1,
  "project": "nextjs-calendar",
  "storyId": "S-001",
  "title": "Core types and interfaces",
  "description": "Define all TypeScript types for the calendar and todo domain.",
  "branchName": "ralph/sprint-1/story-S-001",
  "sprint": "sprint-1",
  "priority": 1,
  "depends_on": [],
  "status": "ready",
  "spec": {
    "scope": "lib/types.ts",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create lib/types.ts with domain interfaces",
      "context": "Create lib/types.ts. Export:\n  - Priority: a type alias for the union 'low' | 'medium' | 'high'\n  - Category: interface with id: string, name: string, color: string\n  - CalendarEvent: interface with id: string, title: string, date: string (ISO), description?: string, categoryId?: string, linkedTodoIds: string[]\n  - Todo: interface with id: string, title: string, done: boolean, priority: Priority, categoryId?: string, dueDate?: string, linkedEventId?: string\nCommit the file.",
      "scope": ["lib/types.ts"],
      "acceptance": "lib/types.ts exists and exports CalendarEvent, Todo, Category, Priority. TypeScript strict typecheck passes.",
      "checks": [
        "test -f lib/types.ts",
        "grep -q 'CalendarEvent' lib/types.ts",
        "grep -q 'Priority' lib/types.ts",
        "grep -q 'Todo' lib/types.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create __tests__/types.test.ts — Jest type-shape tests",
      "context": "Create __tests__/types.test.ts. Import the TypeScript types from '../lib/types'. Write Jest tests using describe/it/expect:\n\n  import type { CalendarEvent, Todo, Category, Priority } from '../lib/types'\n\n  describe('types', () => {\n    it('CalendarEvent can be shaped', () => {\n      const event: CalendarEvent = { id: 'e1', title: 'Meeting', date: '2024-01-01', linkedTodoIds: [] }\n      expect(event.id).toBe('e1')\n      expect(event.linkedTodoIds).toEqual([])\n    })\n    it('Todo has done and priority fields', () => {\n      const todo: Todo = { id: 't1', title: 'Task', done: false, priority: 'high' }\n      expect(todo.done).toBe(false)\n      expect(todo.priority).toBe('high')\n    })\n    it('Priority accepts valid values', () => {\n      const priorities: Priority[] = ['low', 'medium', 'high']\n      expect(priorities).toHaveLength(3)\n    })\n    it('Category has id, name, color', () => {\n      const cat: Category = { id: 'c1', name: 'Work', color: '#ff0000' }\n      expect(cat.color).toBe('#ff0000')\n    })\n  })\n\nCommit the file.",
      "scope": ["__tests__/types.test.ts"],
      "acceptance": "__tests__/types.test.ts exists with passing Jest tests for all type shapes.",
      "checks": [
        "test -f __tests__/types.test.ts",
        "npm test -- --testPathPattern=\"types\\.test\"",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. If any issues are found, fix them and commit. If everything already passes, no commit is needed.",
      "scope": ["lib/types.ts", "__tests__/types.test.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

mkdir -p "$NEXTJS_DIR/scripts/ralph/sprints/sprint-1/stories/S-002"
cat > "$NEXTJS_DIR/scripts/ralph/sprints/sprint-1/stories/S-002/story.json" <<'STORYJSON'
{
  "version": 1,
  "project": "nextjs-calendar",
  "storyId": "S-002",
  "title": "Calendar service",
  "description": "Implement a CalendarStore class with event add, remove, and query operations.",
  "branchName": "ralph/sprint-1/story-S-002",
  "sprint": "sprint-1",
  "priority": 2,
  "depends_on": ["S-001"],
  "status": "ready",
  "spec": {
    "scope": "lib/calendarService.ts and __tests__/calendarService.test.ts",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create lib/calendarService.ts",
      "context": "Create lib/calendarService.ts. Import CalendarEvent from './types'.\nExport a CalendarStore class with:\n  - private events: CalendarEvent[] = []\n  - addEvent(event: CalendarEvent): void\n  - removeEvent(id: string): void  — filters out the matching id\n  - getEventsForDate(date: string): CalendarEvent[]  — returns events where event.date === date\n  - getAllEvents(): CalendarEvent[]  — returns a shallow copy of the array\nAlso export standalone functions that delegate to a store instance:\n  function addEvent(store: CalendarStore, event: CalendarEvent): void\n  function removeEvent(store: CalendarStore, id: string): void\n  function getEventsForDate(store: CalendarStore, date: string): CalendarEvent[]\nCommit the file.",
      "scope": ["lib/calendarService.ts"],
      "acceptance": "lib/calendarService.ts exists, exports CalendarStore and standalone functions. TypeScript strict typecheck passes.",
      "checks": [
        "test -f lib/calendarService.ts",
        "grep -q 'CalendarStore' lib/calendarService.ts",
        "grep -q 'addEvent' lib/calendarService.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create __tests__/calendarService.test.ts — Jest runtime tests",
      "context": "Create __tests__/calendarService.test.ts. Import CalendarStore from '../lib/calendarService'. Write Jest tests:\n\n  import { CalendarStore } from '../lib/calendarService'\n\n  describe('CalendarStore', () => {\n    let store: CalendarStore\n    beforeEach(() => { store = new CalendarStore() })\n\n    it('adds events and queries by date', () => {\n      store.addEvent({ id: 'e1', title: 'A', date: '2024-03-15', linkedTodoIds: [] })\n      store.addEvent({ id: 'e2', title: 'B', date: '2024-03-15', linkedTodoIds: [] })\n      store.addEvent({ id: 'e3', title: 'C', date: '2024-03-16', linkedTodoIds: [] })\n      expect(store.getEventsForDate('2024-03-15')).toHaveLength(2)\n      expect(store.getEventsForDate('2024-03-16')).toHaveLength(1)\n    })\n\n    it('removes an event', () => {\n      store.addEvent({ id: 'e1', title: 'A', date: '2024-03-15', linkedTodoIds: [] })\n      store.removeEvent('e1')\n      expect(store.getAllEvents()).toHaveLength(0)\n    })\n\n    it('getAllEvents returns remaining events', () => {\n      store.addEvent({ id: 'e1', title: 'A', date: '2024-03-15', linkedTodoIds: [] })\n      store.addEvent({ id: 'e2', title: 'B', date: '2024-03-16', linkedTodoIds: [] })\n      store.removeEvent('e1')\n      expect(store.getAllEvents()).toHaveLength(1)\n      expect(store.getAllEvents()[0].id).toBe('e2')\n    })\n  })\n\nCommit the file.",
      "scope": ["__tests__/calendarService.test.ts"],
      "acceptance": "__tests__/calendarService.test.ts exists with passing Jest tests for CalendarStore.",
      "checks": [
        "test -f __tests__/calendarService.test.ts",
        "npm test -- --testPathPattern=\"calendarService\\.test\""
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["lib/calendarService.ts", "__tests__/calendarService.test.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

mkdir -p "$NEXTJS_DIR/scripts/ralph/sprints/sprint-1/stories/S-003"
cat > "$NEXTJS_DIR/scripts/ralph/sprints/sprint-1/stories/S-003/story.json" <<'STORYJSON'
{
  "version": 1,
  "project": "nextjs-calendar",
  "storyId": "S-003",
  "title": "Todo service",
  "description": "Implement a TodoStore class with todo CRUD and priority filtering.",
  "branchName": "ralph/sprint-1/story-S-003",
  "sprint": "sprint-1",
  "priority": 3,
  "depends_on": ["S-001"],
  "status": "ready",
  "spec": {
    "scope": "lib/todoService.ts and __tests__/todoService.test.ts",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create lib/todoService.ts",
      "context": "Create lib/todoService.ts. Import Todo and Priority from './types'.\nExport a TodoStore class with:\n  - private todos: Todo[] = []\n  - createTodo(todo: Todo): void\n  - completeTodo(id: string): void  — sets done = true for the matching id\n  - deleteTodo(id: string): void  — filters out the matching id\n  - filterByPriority(priority: Priority): Todo[]  — returns todos matching the priority\n  - getAllTodos(): Todo[]  — returns a shallow copy\nCommit the file.",
      "scope": ["lib/todoService.ts"],
      "acceptance": "lib/todoService.ts exists, exports TodoStore with createTodo, completeTodo, deleteTodo, filterByPriority. TypeScript strict typecheck passes.",
      "checks": [
        "test -f lib/todoService.ts",
        "grep -q 'TodoStore' lib/todoService.ts",
        "grep -q 'createTodo' lib/todoService.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create __tests__/todoService.test.ts — Jest runtime tests",
      "context": "Create __tests__/todoService.test.ts. Import TodoStore from '../lib/todoService'. Write Jest tests:\n\n  import { TodoStore } from '../lib/todoService'\n\n  describe('TodoStore', () => {\n    let store: TodoStore\n    beforeEach(() => { store = new TodoStore() })\n\n    it('filters by priority', () => {\n      store.createTodo({ id: 't1', title: 'High 1', done: false, priority: 'high' })\n      store.createTodo({ id: 't2', title: 'High 2', done: false, priority: 'high' })\n      store.createTodo({ id: 't3', title: 'Low', done: false, priority: 'low' })\n      expect(store.filterByPriority('high')).toHaveLength(2)\n      expect(store.filterByPriority('low')).toHaveLength(1)\n    })\n\n    it('completes a todo', () => {\n      store.createTodo({ id: 't1', title: 'Task', done: false, priority: 'medium' })\n      store.completeTodo('t1')\n      expect(store.getAllTodos()[0].done).toBe(true)\n    })\n\n    it('deletes a todo', () => {\n      store.createTodo({ id: 't1', title: 'A', done: false, priority: 'low' })\n      store.createTodo({ id: 't2', title: 'B', done: false, priority: 'high' })\n      store.deleteTodo('t1')\n      expect(store.getAllTodos()).toHaveLength(1)\n      expect(store.getAllTodos()[0].id).toBe('t2')\n    })\n  })\n\nCommit the file.",
      "scope": ["__tests__/todoService.test.ts"],
      "acceptance": "__tests__/todoService.test.ts exists with passing Jest tests for TodoStore.",
      "checks": [
        "test -f __tests__/todoService.test.ts",
        "npm test -- --testPathPattern=\"todoService\\.test\""
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["lib/todoService.ts", "__tests__/todoService.test.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

mkdir -p "$NEXTJS_DIR/scripts/ralph/sprints/sprint-1/stories/S-004"
cat > "$NEXTJS_DIR/scripts/ralph/sprints/sprint-1/stories/S-004/story.json" <<'STORYJSON'
{
  "version": 1,
  "project": "nextjs-calendar",
  "storyId": "S-004",
  "title": "Barrel export and integration test",
  "description": "Wire all modules through lib/index.ts and add a cross-module integration test.",
  "branchName": "ralph/sprint-1/story-S-004",
  "sprint": "sprint-1",
  "priority": 4,
  "depends_on": ["S-001", "S-002", "S-003"],
  "status": "ready",
  "spec": {
    "scope": "lib/index.ts and __tests__/integration.test.ts",
    "preserved_invariants": [
      "APP_NAME and APP_VERSION exports must remain in lib/index.ts",
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Update lib/index.ts to re-export all modules",
      "context": "Update lib/index.ts (which currently only exports APP_NAME and APP_VERSION). Add re-exports:\n  export * from './calendarService'\n  export * from './todoService'\n  export * from './types'\nKeep the existing APP_NAME and APP_VERSION exports. Commit the change.",
      "scope": ["lib/index.ts"],
      "acceptance": "lib/index.ts re-exports calendarService, todoService, and types. APP_NAME and APP_VERSION remain. TypeScript strict typecheck passes.",
      "checks": [
        "grep -q 'calendarService' lib/index.ts",
        "grep -q 'todoService' lib/index.ts",
        "grep -q 'APP_NAME' lib/index.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create __tests__/integration.test.ts — cross-module Jest test",
      "context": "Create __tests__/integration.test.ts. Import from the barrel lib/index.ts. Write Jest tests:\n\n  import { CalendarStore, TodoStore, APP_NAME } from '../lib/index'\n\n  describe('integration', () => {\n    it('APP_NAME is exported from barrel', () => {\n      expect(APP_NAME).toBe('nextjs-calendar')\n    })\n\n    it('CalendarStore and TodoStore work together', () => {\n      const calStore = new CalendarStore()\n      const todoStore = new TodoStore()\n\n      calStore.addEvent({ id: 'e1', title: 'Standup', date: '2024-04-01', linkedTodoIds: ['t1'] })\n      todoStore.createTodo({ id: 't1', title: 'Prepare agenda', done: false, priority: 'high' })\n\n      expect(calStore.getEventsForDate('2024-04-01')).toHaveLength(1)\n      expect(calStore.getEventsForDate('2024-04-01')[0].title).toBe('Standup')\n      expect(todoStore.filterByPriority('high')).toHaveLength(1)\n\n      todoStore.completeTodo('t1')\n      expect(todoStore.getAllTodos()[0].done).toBe(true)\n\n      const event = calStore.getAllEvents()[0]\n      expect(event.linkedTodoIds).toContain('t1')\n    })\n  })\n\nCommit the file.",
      "scope": ["__tests__/integration.test.ts"],
      "acceptance": "__tests__/integration.test.ts exists with passing cross-module Jest assertions.",
      "checks": [
        "test -f __tests__/integration.test.ts",
        "npm test -- --testPathPattern=\"integration\\.test\""
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["lib/index.ts", "__tests__/integration.test.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass including integration.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

fi  # end GENERATED guard for nextjs story.json

# Write ralph-sprint-test.sh for nextjs-calendar
cat > "$NEXTJS_DIR/scripts/ralph/ralph-sprint-test.sh" <<'SH'
#!/bin/bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
npm run build && npm run typecheck && npm test
SH
chmod +x "$NEXTJS_DIR/scripts/ralph/ralph-sprint-test.sh"

commit_baseline "$NEXTJS_DIR" "chore(smoke): nextjs-calendar sprint plan"


# ══════════════════════════════════════════════════════════════════════════════
#  PROJECT 2: angular-calendar
#  Real Angular project via ng new. Services in src/app/services/.
#  Tests as *.spec.ts using Jest + ts-jest.
# ══════════════════════════════════════════════════════════════════════════════

log "=== Setting up angular-calendar ==="

cd "$WORK_DIR"
log "  Running ng new..."
npx @angular/cli@latest new angular-calendar \
  --routing=false \
  --style=css \
  --skip-git \
  --standalone \
  --defaults \
  > "$LOG_DIR/angular-create.log" 2>&1 \
  || fail "ng new failed — see $LOG_DIR/angular-create.log"

cd "$ANGULAR_DIR"
git init -b main >/dev/null
git config user.name "Ralph Smoke"
git config user.email "ralph-smoke@example.com"

# Remove generated Karma/Jasmine spec files — incompatible with Jest
find src -name "*.spec.ts" -delete 2>/dev/null || true

log "  Adding Jest..."
npm install --save-dev jest @types/jest ts-jest jest-environment-node --silent \
  >> "$LOG_DIR/angular-create.log" 2>&1

npm pkg set scripts.test="jest"
npm pkg set scripts.typecheck="tsc --noEmit"

cat > jest.config.ts <<'TS'
import type { Config } from 'jest'

const config: Config = {
  transform: {
    '^.+\\.tsx?$': ['ts-jest', {
      tsconfig: {
        module: 'commonjs',
        moduleResolution: 'node',
        experimentalDecorators: true,
        emitDecoratorMetadata: true,
      },
    }],
  },
  testEnvironment: 'node',
  testMatch: ['**/*.spec.ts'],
  testPathIgnorePatterns: ['/node_modules/', '/dist/'],
}

export default config
TS

# Minimal baseline spec replacing deleted generated one
cat > src/app/app.spec.ts <<'SPEC'
describe('app', () => {
  it('is configured', () => {
    expect(true).toBe(true)
  })
})
SPEC

git add .
git reset -- dist >/dev/null 2>&1 || true
git commit -m "chore: init angular-calendar" >/dev/null

log "  installing ralph framework..."
HOME="$WORK_DIR/home-angular" "$REPO_ROOT/install.sh" \
  --project "$ANGULAR_DIR" > "$LOG_DIR/install-angular.log" 2>&1
assert_file_exists "$ANGULAR_DIR/scripts/ralph/ralph.sh"
assert_file_exists "$ANGULAR_DIR/scripts/ralph/ralph-task.sh"
assert_file_exists "$ANGULAR_DIR/scripts/ralph/ralph-sprint-commit.sh"
assert_file_exists "$ANGULAR_DIR/scripts/ralph/doctor.sh"

# ── Angular sprint scaffold ────────────────────────────────────────────────────

(
  cd "$ANGULAR_DIR/scripts/ralph"

  ./ralph-sprint.sh create sprint-1 > "$LOG_DIR/angular-sprint-create.log" 2>&1
  assert_contains "$LOG_DIR/angular-sprint-create.log" "Created sprint: sprint-1"

  ./ralph-story.sh add --title "Data models" \
    --goal "Define class-based domain models for calendar events, todos, and categories." \
    --prompt-context "Create src/app/models.ts with class CalendarEvent, class Todo, class Category." \
    > "$LOG_DIR/angular-story-add-S-001.log" 2>&1

  ./ralph-story.sh add --title "CalendarService class" \
    --goal "Implement CalendarService as a class with Map-backed event storage." \
    --prompt-context "Create src/app/services/calendar.service.ts with class CalendarService." \
    > "$LOG_DIR/angular-story-add-S-002.log" 2>&1

  ./ralph-story.sh add --title "TodoService class" \
    --goal "Implement TodoService as a class with Map-backed todo storage." \
    --prompt-context "Create src/app/services/todo.service.ts with class TodoService." \
    > "$LOG_DIR/angular-story-add-S-003.log" 2>&1

  ./ralph-story.sh add --title "AppModule wiring and integration" \
    --goal "Create AppModule class that wires CalendarService and TodoService together." \
    --prompt-context "Create src/app/app.module.ts with class AppModule having a static create() factory." \
    > "$LOG_DIR/angular-story-add-S-004.log" 2>&1

  # Patch story-level depends_on into stories.json.
  # ralph-story.sh add does not yet accept --depends-on (known framework gap).
  _sf="sprints/sprint-1/stories.json"
  _tmp="$(mktemp)"
  jq '
    .stories = [.stories[] |
      if   .id == "S-002" then .depends_on = ["S-001"]
      elif .id == "S-003" then .depends_on = ["S-001"]
      elif .id == "S-004" then .depends_on = ["S-001", "S-002", "S-003"]
      else . end
    ]
  ' "$_sf" > "$_tmp" && mv "$_tmp" "$_sf"
)

# ── Angular doctor check ───────────────────────────────────────────────────────

doctor_check "$ANGULAR_DIR" "angular"

# ── Angular story.json definitions ────────────────────────────────────────────

if [ "$GENERATED" -eq 1 ]; then
  generate_stories "$ANGULAR_DIR" "angular"
else

mkdir -p "$ANGULAR_DIR/scripts/ralph/sprints/sprint-1/stories/S-001"
cat > "$ANGULAR_DIR/scripts/ralph/sprints/sprint-1/stories/S-001/story.json" <<'STORYJSON'
{
  "version": 1,
  "project": "angular-calendar",
  "storyId": "S-001",
  "title": "Data models",
  "description": "Define class-based domain models used throughout the app.",
  "branchName": "ralph/sprint-1/story-S-001",
  "sprint": "sprint-1",
  "priority": 1,
  "depends_on": [],
  "status": "ready",
  "spec": {
    "scope": "src/app/models.ts",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create src/app/models.ts with class-based models",
      "context": "Create src/app/models.ts. Export three classes:\n\n  export class CalendarEvent {\n    constructor(\n      public id: string,\n      public title: string,\n      public date: string,\n      public description: string = '',\n      public linkedTodoIds: string[] = []\n    ) {}\n  }\n\n  export class Todo {\n    public done: boolean = false\n    constructor(\n      public id: string,\n      public title: string,\n      public priority: 'low' | 'medium' | 'high' = 'medium',\n      public dueDate?: string\n    ) {}\n  }\n\n  export class Category {\n    constructor(\n      public id: string,\n      public name: string,\n      public color: string\n    ) {}\n  }\n\nCommit the file.",
      "scope": ["src/app/models.ts"],
      "acceptance": "src/app/models.ts exists and exports class CalendarEvent, class Todo, class Category. TypeScript strict typecheck passes.",
      "checks": [
        "test -f src/app/models.ts",
        "grep -q 'class CalendarEvent' src/app/models.ts",
        "grep -q 'class Todo' src/app/models.ts",
        "grep -q 'class Category' src/app/models.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create src/app/models.spec.ts — Jest class instantiation tests",
      "context": "Create src/app/models.spec.ts. Import the model classes from './models'. Write Jest tests:\n\n  import { CalendarEvent, Todo, Category } from './models'\n\n  describe('CalendarEvent', () => {\n    it('sets defaults for description and linkedTodoIds', () => {\n      const e = new CalendarEvent('e1', 'Meeting', '2024-01-01')\n      expect(e.id).toBe('e1')\n      expect(e.description).toBe('')\n      expect(e.linkedTodoIds).toEqual([])\n    })\n  })\n\n  describe('Todo', () => {\n    it('defaults done to false and priority to medium', () => {\n      const t = new Todo('t1', 'Task')\n      expect(t.done).toBe(false)\n      expect(t.priority).toBe('medium')\n    })\n    it('accepts explicit priority', () => {\n      const t = new Todo('t2', 'Urgent', 'high')\n      expect(t.priority).toBe('high')\n    })\n  })\n\n  describe('Category', () => {\n    it('stores id, name, color', () => {\n      const c = new Category('c1', 'Work', '#ff0000')\n      expect(c.name).toBe('Work')\n      expect(c.color).toBe('#ff0000')\n    })\n  })\n\nCommit the file.",
      "scope": ["src/app/models.spec.ts"],
      "acceptance": "src/app/models.spec.ts exists with passing Jest tests for all model classes.",
      "checks": [
        "test -f src/app/models.spec.ts",
        "npm test -- --testPathPattern=\"models\\.spec\"",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["src/app/models.ts", "src/app/models.spec.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

mkdir -p "$ANGULAR_DIR/scripts/ralph/sprints/sprint-1/stories/S-002"
cat > "$ANGULAR_DIR/scripts/ralph/sprints/sprint-1/stories/S-002/story.json" <<'STORYJSON'
{
  "version": 1,
  "project": "angular-calendar",
  "storyId": "S-002",
  "title": "CalendarService class",
  "description": "Implement CalendarService as a class with Map-backed event storage.",
  "branchName": "ralph/sprint-1/story-S-002",
  "sprint": "sprint-1",
  "priority": 2,
  "depends_on": ["S-001"],
  "status": "ready",
  "spec": {
    "scope": "src/app/services/calendar.service.ts and src/app/services/calendar.service.spec.ts",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create src/app/services/calendar.service.ts",
      "context": "Create src/app/services/calendar.service.ts. Import CalendarEvent from '../models'.\nExport class CalendarService with:\n  - private events: Map<string, CalendarEvent> = new Map()\n  - addEvent(event: CalendarEvent): void  — sets events.set(event.id, event)\n  - removeEvent(id: string): boolean  — returns events.delete(id)\n  - getEventsForDate(date: string): CalendarEvent[]  — filters by event.date === date\n  - getAllEvents(): CalendarEvent[]  — returns Array.from(events.values())\nCommit the file.",
      "scope": ["src/app/services/calendar.service.ts"],
      "acceptance": "src/app/services/calendar.service.ts exists, exports class CalendarService with addEvent, removeEvent, getEventsForDate. TypeScript strict typecheck passes.",
      "checks": [
        "test -f src/app/services/calendar.service.ts",
        "grep -q 'class CalendarService' src/app/services/calendar.service.ts",
        "grep -q 'addEvent' src/app/services/calendar.service.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create src/app/services/calendar.service.spec.ts — Jest tests",
      "context": "Create src/app/services/calendar.service.spec.ts. Import CalendarService and CalendarEvent. Write Jest tests:\n\n  import { CalendarService } from './calendar.service'\n  import { CalendarEvent } from '../models'\n\n  describe('CalendarService', () => {\n    let service: CalendarService\n    beforeEach(() => { service = new CalendarService() })\n\n    it('adds events and queries by date', () => {\n      service.addEvent(new CalendarEvent('e1', 'A', '2024-05-01'))\n      service.addEvent(new CalendarEvent('e2', 'B', '2024-05-01'))\n      service.addEvent(new CalendarEvent('e3', 'C', '2024-05-02'))\n      expect(service.getEventsForDate('2024-05-01')).toHaveLength(2)\n      expect(service.getEventsForDate('2024-05-02')).toHaveLength(1)\n    })\n\n    it('removes an event and returns true', () => {\n      service.addEvent(new CalendarEvent('e1', 'A', '2024-05-01'))\n      expect(service.removeEvent('e1')).toBe(true)\n      expect(service.getAllEvents()).toHaveLength(0)\n    })\n\n    it('removeEvent returns false for unknown id', () => {\n      expect(service.removeEvent('nonexistent')).toBe(false)\n    })\n  })\n\nCommit the file.",
      "scope": ["src/app/services/calendar.service.spec.ts"],
      "acceptance": "src/app/services/calendar.service.spec.ts exists with passing Jest tests for CalendarService.",
      "checks": [
        "test -f src/app/services/calendar.service.spec.ts",
        "npm test -- --testPathPattern=\"calendar\\.service\\.spec\""
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["src/app/services/calendar.service.ts", "src/app/services/calendar.service.spec.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

mkdir -p "$ANGULAR_DIR/scripts/ralph/sprints/sprint-1/stories/S-003"
cat > "$ANGULAR_DIR/scripts/ralph/sprints/sprint-1/stories/S-003/story.json" <<'STORYJSON'
{
  "version": 1,
  "project": "angular-calendar",
  "storyId": "S-003",
  "title": "TodoService class",
  "description": "Implement TodoService as a class with Map-backed todo storage.",
  "branchName": "ralph/sprint-1/story-S-003",
  "sprint": "sprint-1",
  "priority": 3,
  "depends_on": ["S-001"],
  "status": "ready",
  "spec": {
    "scope": "src/app/services/todo.service.ts and src/app/services/todo.service.spec.ts",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create src/app/services/todo.service.ts",
      "context": "Create src/app/services/todo.service.ts. Import Todo from '../models'.\nExport class TodoService with:\n  - private todos: Map<string, Todo> = new Map()\n  - create(todo: Todo): void  — sets todos.set(todo.id, todo)\n  - complete(id: string): void  — finds the todo and sets done = true\n  - delete(id: string): boolean  — returns todos.delete(id)\n  - getByPriority(priority: 'low' | 'medium' | 'high'): Todo[]  — filters by todo.priority\n  - getAll(): Todo[]  — returns Array.from(todos.values())\nCommit the file.",
      "scope": ["src/app/services/todo.service.ts"],
      "acceptance": "src/app/services/todo.service.ts exists, exports class TodoService with create, complete, delete, getByPriority. TypeScript strict typecheck passes.",
      "checks": [
        "test -f src/app/services/todo.service.ts",
        "grep -q 'class TodoService' src/app/services/todo.service.ts",
        "grep -q 'getByPriority' src/app/services/todo.service.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create src/app/services/todo.service.spec.ts — Jest tests",
      "context": "Create src/app/services/todo.service.spec.ts. Import TodoService and Todo. Write Jest tests:\n\n  import { TodoService } from './todo.service'\n  import { Todo } from '../models'\n\n  describe('TodoService', () => {\n    let service: TodoService\n    beforeEach(() => { service = new TodoService() })\n\n    it('filters by priority', () => {\n      service.create(new Todo('t1', 'High 1', 'high'))\n      service.create(new Todo('t2', 'High 2', 'high'))\n      service.create(new Todo('t3', 'Low', 'low'))\n      expect(service.getByPriority('high')).toHaveLength(2)\n      expect(service.getByPriority('low')).toHaveLength(1)\n    })\n\n    it('completes a todo', () => {\n      service.create(new Todo('t1', 'Task', 'medium'))\n      service.complete('t1')\n      expect(service.getAll()[0].done).toBe(true)\n    })\n\n    it('deletes a todo and returns true', () => {\n      service.create(new Todo('t1', 'A', 'low'))\n      service.create(new Todo('t2', 'B', 'high'))\n      expect(service.delete('t1')).toBe(true)\n      expect(service.getAll()).toHaveLength(1)\n      expect(service.getAll()[0].id).toBe('t2')\n    })\n  })\n\nCommit the file.",
      "scope": ["src/app/services/todo.service.spec.ts"],
      "acceptance": "src/app/services/todo.service.spec.ts exists with passing Jest tests for TodoService.",
      "checks": [
        "test -f src/app/services/todo.service.spec.ts",
        "npm test -- --testPathPattern=\"todo\\.service\\.spec\""
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["src/app/services/todo.service.ts", "src/app/services/todo.service.spec.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

mkdir -p "$ANGULAR_DIR/scripts/ralph/sprints/sprint-1/stories/S-004"
cat > "$ANGULAR_DIR/scripts/ralph/sprints/sprint-1/stories/S-004/story.json" <<'STORYJSON'
{
  "version": 1,
  "project": "angular-calendar",
  "storyId": "S-004",
  "title": "AppModule wiring and integration",
  "description": "Create AppModule that wires CalendarService and TodoService, with cross-service integration tests.",
  "branchName": "ralph/sprint-1/story-S-004",
  "sprint": "sprint-1",
  "priority": 4,
  "depends_on": ["S-001", "S-002", "S-003"],
  "status": "ready",
  "spec": {
    "scope": "src/app/app.module.ts and src/app/app.module.spec.ts",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create src/app/app.module.ts",
      "context": "Create src/app/app.module.ts. Import CalendarService from './services/calendar.service' and TodoService from './services/todo.service'.\nExport:\n  export interface AppServices {\n    calendarService: CalendarService\n    todoService: TodoService\n  }\n  export class AppModule {\n    static create(): AppServices {\n      return {\n        calendarService: new CalendarService(),\n        todoService: new TodoService(),\n      }\n    }\n  }\nCommit the file.",
      "scope": ["src/app/app.module.ts"],
      "acceptance": "src/app/app.module.ts exists, exports class AppModule with static create() returning AppServices. TypeScript strict typecheck passes.",
      "checks": [
        "test -f src/app/app.module.ts",
        "grep -q 'class AppModule' src/app/app.module.ts",
        "grep -q 'AppServices' src/app/app.module.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create src/app/app.module.spec.ts — cross-service Jest integration",
      "context": "Create src/app/app.module.spec.ts. Import AppModule, CalendarEvent, Todo. Write Jest tests:\n\n  import { AppModule } from './app.module'\n  import { CalendarEvent, Todo } from './models'\n\n  describe('AppModule', () => {\n    it('create() returns services with empty state', () => {\n      const { calendarService, todoService } = AppModule.create()\n      expect(calendarService.getAllEvents()).toHaveLength(0)\n      expect(todoService.getAll()).toHaveLength(0)\n    })\n\n    it('instances are independent across create() calls', () => {\n      const app1 = AppModule.create()\n      const app2 = AppModule.create()\n      app1.calendarService.addEvent(new CalendarEvent('e1', 'Meeting', '2024-06-01'))\n      expect(app1.calendarService.getAllEvents()).toHaveLength(1)\n      expect(app2.calendarService.getAllEvents()).toHaveLength(0)\n    })\n\n    it('cross-service integration', () => {\n      const { calendarService, todoService } = AppModule.create()\n      calendarService.addEvent(new CalendarEvent('e1', 'Standup', '2024-06-01'))\n      todoService.create(new Todo('t1', 'Agenda', 'high'))\n      expect(calendarService.getEventsForDate('2024-06-01')).toHaveLength(1)\n      expect(todoService.getByPriority('high')).toHaveLength(1)\n      todoService.complete('t1')\n      expect(todoService.getAll()[0].done).toBe(true)\n    })\n  })\n\nCommit the file.",
      "scope": ["src/app/app.module.spec.ts"],
      "acceptance": "src/app/app.module.spec.ts exists with passing cross-service Jest integration assertions.",
      "checks": [
        "test -f src/app/app.module.spec.ts",
        "npm test -- --testPathPattern=\"app\\.module\\.spec\""
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run typecheck, and npm test. Fix any issues and commit if needed.",
      "scope": ["src/app/app.module.ts", "src/app/app.module.spec.ts"],
      "acceptance": "Build succeeds. TypeScript typecheck passes. All tests pass including integration.",
      "checks": [
        "npm run build",
        "npm run typecheck",
        "npm test"
      ],
      "depends_on": ["T-02"],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON

fi  # end GENERATED guard for angular story.json

# Write ralph-sprint-test.sh for angular-calendar
cat > "$ANGULAR_DIR/scripts/ralph/ralph-sprint-test.sh" <<'SH'
#!/bin/bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
npm run build && npm run typecheck && npm test
SH
chmod +x "$ANGULAR_DIR/scripts/ralph/ralph-sprint-test.sh"

commit_baseline "$ANGULAR_DIR" "chore(smoke): angular-calendar sprint plan"


# ══════════════════════════════════════════════════════════════════════════════
#  VALIDATION PHASE
#  Schema, dependency, and health checks for both projects before execution.
# ══════════════════════════════════════════════════════════════════════════════

log ""
log "════════════════════════════════════════"
log "  VALIDATION PHASE"
log "════════════════════════════════════════"

for proj_label in nextjs angular; do
  if [ "$proj_label" = "nextjs" ]; then
    proj_dir="$NEXTJS_DIR"
  else
    proj_dir="$ANGULAR_DIR"
  fi

  ralph_dir="$proj_dir/scripts/ralph"
  log ""
  log "--- Validating $proj_label-calendar ---"

  # Schema + dependency validation
  validate_sprint "$ralph_dir" "sprint-1"

  # ralph-story.sh health — fatal if any story has structural issues
  for sid in S-001 S-002 S-003 S-004; do
    hlog="$LOG_DIR/${proj_label}-health-${sid}.log"
    if ! (cd "$ralph_dir" && ./ralph-story.sh health "$sid" > "$hlog" 2>&1); then
      log "  FAIL: health check for $proj_label $sid — see $hlog"
      cat "$hlog" >&2
      fail "Story health check failed: $proj_label $sid"
    fi
    log "  health OK: $proj_label $sid"
  done
done

log ""
log "Validation complete — both projects structurally sound."


# ══════════════════════════════════════════════════════════════════════════════
#  EXECUTION PHASE
# ══════════════════════════════════════════════════════════════════════════════

log ""
log "════════════════════════════════════════"
log "  EXECUTION PHASE"
log "════════════════════════════════════════"

NEXTJS_EXIT=0
ANGULAR_EXIT=0
NEXTJS_COMMIT_EXIT=0
ANGULAR_COMMIT_EXIT=0

log ""
log "--- Running nextjs-calendar sprint ---"
run_sprint "$NEXTJS_DIR" "nextjs" || NEXTJS_EXIT=$?

if [ "$NEXTJS_EXIT" -eq 0 ]; then
  log ""
  log "--- Post-sprint: nextjs-calendar ---"
  (cd "$NEXTJS_DIR/scripts/ralph" && ./ralph-status.sh) \
    > "$LOG_DIR/nextjs-status.log" 2>&1 || true
  log "  ralph-status logged to: $LOG_DIR/nextjs-status.log"
  run_sprint_commit "$NEXTJS_DIR" "nextjs" || NEXTJS_COMMIT_EXIT=$?
fi

log ""
log "--- Running angular-calendar sprint ---"
run_sprint "$ANGULAR_DIR" "angular" || ANGULAR_EXIT=$?

if [ "$ANGULAR_EXIT" -eq 0 ]; then
  log ""
  log "--- Post-sprint: angular-calendar ---"
  (cd "$ANGULAR_DIR/scripts/ralph" && ./ralph-status.sh) \
    > "$LOG_DIR/angular-status.log" 2>&1 || true
  log "  ralph-status logged to: $LOG_DIR/angular-status.log"
  run_sprint_commit "$ANGULAR_DIR" "angular" || ANGULAR_COMMIT_EXIT=$?
fi


# ══════════════════════════════════════════════════════════════════════════════
#  REPORT PHASE
# ══════════════════════════════════════════════════════════════════════════════

log ""
log "════════════════════════════════════════"
log "  FINAL REPORT"
log "════════════════════════════════════════"

overall_exit=0

for proj_label in nextjs angular; do
  if [ "$proj_label" = "nextjs" ]; then
    proj_dir="$NEXTJS_DIR"
    sprint_exit=$NEXTJS_EXIT
    commit_exit=$NEXTJS_COMMIT_EXIT
  else
    proj_dir="$ANGULAR_DIR"
    sprint_exit=$ANGULAR_EXIT
    commit_exit=$ANGULAR_COMMIT_EXIT
  fi

  sprint_log="$LOG_DIR/${proj_label}-sprint.log"
  stories_file="$proj_dir/scripts/ralph/sprints/sprint-1/stories.json"

  echo ""
  echo "── $proj_label-calendar ──────────────────────────────────────"

  # Story completion from stories.json
  if [ -f "$stories_file" ]; then
    done_count="$(count_stories_done "$stories_file")"
    total_count="$(jq '.stories | length' "$stories_file" 2>/dev/null || echo '?')"
    echo "  Stories done: $done_count / $total_count"
    jq -r '.stories[] | "  \(.id): \(.status) (passes=\(.passes))"' "$stories_file" 2>/dev/null || true
  else
    echo "  WARNING: stories.json not found"
  fi

  # Story status lines from log
  echo ""
  echo "  Loop output summary:"
  extract_story_status "$sprint_log" | sed 's/^/    /' || echo "    (no story-complete markers found)"

  # Structural failures
  struct_failures="$(extract_structural_failures "$sprint_log")"
  if [ -n "$struct_failures" ]; then
    echo ""
    echo "  Structural failures caught (short-circuited early):"
    echo "$struct_failures" | sed 's/^/    /'
  fi

  # Task failures
  task_failures="$(extract_task_failures "$sprint_log")"
  if [ -n "$task_failures" ]; then
    echo ""
    echo "  Tasks that exhausted retries:"
    echo "$task_failures" | sed 's/^/    /'
    overall_exit=1
  fi

  # Sprint exit
  if [ "$sprint_exit" -eq 0 ]; then
    echo ""
    echo "  Sprint exit: PASS"
  else
    echo ""
    echo "  Sprint exit: FAIL (exit $sprint_exit)"
    overall_exit=1
  fi

  # Post-sprint assertions
  echo ""
  echo "  Post-sprint assertions:"

  if [ -f "$stories_file" ]; then
    if jq -e 'all(.stories[]; .status == "done" and .passes == true)' \
         "$stories_file" > /dev/null 2>&1; then
      echo "    All stories done=true, passes=true: PASS"
    else
      echo "    Some stories not done/passing: FAIL"
      overall_exit=1
    fi
  fi

  # Sprint status closed after commit
  if [ "$sprint_exit" -eq 0 ]; then
    if [ "$commit_exit" -eq 0 ]; then
      sprint_status="$(jq -r '.status // "unknown"' "$stories_file" 2>/dev/null || echo "unknown")"
      echo "    ralph-sprint-commit: PASS (status=$sprint_status)"
    else
      echo "    ralph-sprint-commit: FAIL"
      overall_exit=1
    fi
  fi

  # ralph-verify: standalone build + typecheck + test on final merged state
  if [ "$sprint_exit" -eq 0 ] && [ "$commit_exit" -eq 0 ]; then
    verify_log="$LOG_DIR/${proj_label}-verify.log"
    if (cd "$proj_dir/scripts/ralph" && ./ralph-verify.sh --full) > "$verify_log" 2>&1; then
      echo "    ralph-verify --full: PASS"
    else
      echo "    ralph-verify --full: FAIL"
      overall_exit=1
    fi
  fi

done

# ── Behavioral observations ────────────────────────────────────────────────────

echo ""
echo "── Behavioral observations ───────────────────────────────────"
for proj_label in nextjs angular; do
  sprint_log="$LOG_DIR/${proj_label}-sprint.log"
  retries="$(awk '/Retrying\.\.\./{c++} END{print c+0}' "$sprint_log" 2>/dev/null || echo 0)"
  structural="$(grep -c "STRUCTURAL FAILURE" "$sprint_log" 2>/dev/null || echo 0)"
  blocked="$(grep -c "BLOCKED — dependencies" "$sprint_log" 2>/dev/null || echo 0)"
  echo "  $proj_label: retries=$retries  structural_short_circuits=$structural  blocked=$blocked"
done

# ── Generation mode note ───────────────────────────────────────────────────────

if [ "$GENERATED" -eq 1 ]; then
  echo ""
  echo "  Mode: --generated (story.json files produced by ralph-story.sh generate)"
else
  echo ""
  echo "  Mode: default (hand-written story.json task plans)"
fi

echo ""

if [ "$overall_exit" -eq 0 ]; then
  log "PASS — both calendar projects completed sprint-1 successfully"
else
  log "FAIL — one or more assertions failed (see above)"
fi

if [ "$KEEP" -eq 1 ]; then
  echo ""
  echo "[smoke] work dir retained for inspection: $WORK_DIR"
  echo "  nextjs:   $NEXTJS_DIR"
  echo "  angular:  $ANGULAR_DIR"
  echo "  logs:     $LOG_DIR"
fi
