#!/bin/bash
# e2e-calendar.sh — Full end-to-end Calendar + Todo app smoke test
#
# Exercises the complete Ralph lifecycle for two TypeScript projects:
#
#   nextjs-calendar  — Next.js-style modular TypeScript (functional services,
#                      barrel exports, hook/context patterns)
#   angular-calendar — Angular-style TypeScript (class-based services,
#                      constructor injection, Map-backed state)
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

# Write the shared test runner script into a project
write_run_tests_mjs() {
  local proj="$1"
  mkdir -p "$proj/scripts"
  cat > "$proj/scripts/run-tests.mjs" <<'JS'
import assert from "node:assert/strict";
import { readdirSync, statSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const argv = process.argv.slice(2);
let runTestsByPath = [];

for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--runTestsByPath") {
    i++;
    while (i < argv.length && !argv[i].startsWith("--")) {
      runTestsByPath.push(argv[i++]);
    }
    i--;
  }
}

function collectTests(dir) {
  const files = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) { files.push(...collectTests(full)); continue; }
    if (/(\.test|\.spec)\.m?js$/.test(e.name)) files.push(full);
  }
  return files;
}

const tests = runTestsByPath.length > 0
  ? runTestsByPath.map(p => path.resolve(p))
  : collectTests("tests").map(p => path.resolve(p));

assert.ok(tests.length > 0, "No tests discovered");
for (const t of tests) await import(pathToFileURL(t).href);
console.log(`PASS ${tests.length} test file(s)`);
console.log("test ok");
JS
}

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
#  Next.js-style TypeScript: functional services, barrel exports
# ══════════════════════════════════════════════════════════════════════════════

log "=== Setting up nextjs-calendar ==="

mkdir -p "$NEXTJS_DIR"
cd "$NEXTJS_DIR"
git init -b main >/dev/null
git config user.name "Ralph Smoke"
git config user.email "ralph-smoke@example.com"

cat > package.json <<'JSON'
{
  "name": "nextjs-calendar",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build":     "tsc -p tsconfig.json",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "lint":      "node -e \"console.log('lint ok')\"",
    "test":      "node scripts/run-tests.mjs"
  },
  "devDependencies": {
    "typescript": "^5.4.5"
  }
}
JSON

cat > tsconfig.json <<'JSON'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
JSON

mkdir -p src
cat > src/index.ts <<'TS'
export const APP_NAME = "nextjs-calendar";
export const APP_VERSION = "0.1.0";
TS

write_run_tests_mjs "$NEXTJS_DIR"

mkdir -p tests
cat > tests/baseline.test.mjs <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
const src = readFileSync("src/index.ts", "utf8");
assert.ok(src.includes("nextjs-calendar"), "APP_NAME missing from src/index.ts");
JS

cat > .gitignore <<'EOF'
dist/
node_modules/
EOF

log "  npm install..."
npm install --silent
npm run build --silent

git add .
git reset -- dist >/dev/null 2>&1 || true
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
    --prompt-context "Create src/types.ts with CalendarEvent, Todo, Category interfaces and a Priority type." \
    > "$LOG_DIR/nextjs-story-add-S-001.log" 2>&1

  ./ralph-story.sh add --title "Calendar service" \
    --goal "Implement a CalendarStore class with add/remove/query operations." \
    --prompt-context "Create src/calendarService.ts importing CalendarEvent from types." \
    > "$LOG_DIR/nextjs-story-add-S-002.log" 2>&1

  ./ralph-story.sh add --title "Todo service" \
    --goal "Implement a TodoStore class with CRUD and priority filtering." \
    --prompt-context "Create src/todoService.ts importing Todo, Priority from types." \
    > "$LOG_DIR/nextjs-story-add-S-003.log" 2>&1

  ./ralph-story.sh add --title "Barrel export and integration" \
    --goal "Wire all modules through src/index.ts and add cross-module integration test." \
    --prompt-context "Update src/index.ts to re-export calendarService, todoService, types. Add tests/integration.test.mjs." \
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
    "scope": "src/types.ts",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create src/types.ts with domain interfaces",
      "context": "Create src/types.ts. Export:\n  - Priority: a type alias for the union 'low' | 'medium' | 'high'\n  - Category: interface with id: string, name: string, color: string\n  - CalendarEvent: interface with id: string, title: string, date: string (ISO), description?: string, categoryId?: string, linkedTodoIds: string[]\n  - Todo: interface with id: string, title: string, done: boolean, priority: Priority, categoryId?: string, dueDate?: string, linkedEventId?: string\nCommit the file.",
      "scope": ["src/types.ts"],
      "acceptance": "src/types.ts exists and exports CalendarEvent, Todo, Category, Priority. TypeScript strict typecheck passes.",
      "checks": [
        "test -f src/types.ts",
        "grep -q 'CalendarEvent' src/types.ts",
        "grep -q 'Priority' src/types.ts",
        "grep -q 'Todo' src/types.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create tests/types.test.mjs — source inspection",
      "context": "Create tests/types.test.mjs. Use readFileSync to read src/types.ts and assert that the following strings are present in the source: 'CalendarEvent', 'Todo', 'Priority', 'Category', 'linkedTodoIds'. Commit the file.",
      "scope": ["tests/types.test.mjs"],
      "acceptance": "tests/types.test.mjs exists and asserts all required type symbols are present. Test passes.",
      "checks": [
        "test -f tests/types.test.mjs",
        "npm test -- --runTestsByPath tests/types.test.mjs",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run lint, and npm test. If any issues are found, fix them and commit. If everything already passes, no commit is needed.",
      "scope": ["src/types.ts", "tests/types.test.mjs"],
      "acceptance": "Build succeeds. Lint passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run lint",
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
    "scope": "src/calendarService.ts and tests/calendarService.test.mjs",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create src/calendarService.ts",
      "context": "Create src/calendarService.ts. Import CalendarEvent from './types.js' (NodeNext requires .js extension).\nExport a CalendarStore class with:\n  - private events: CalendarEvent[] = []\n  - addEvent(event: CalendarEvent): void\n  - removeEvent(id: string): void  — filters out the matching id\n  - getEventsForDate(date: string): CalendarEvent[]  — returns events where event.date === date\n  - getAllEvents(): CalendarEvent[]  — returns a copy of the array\nAlso export standalone functions that delegate to a CalendarStore instance:\n  function addEvent(store: CalendarStore, event: CalendarEvent): void\n  function removeEvent(store: CalendarStore, id: string): void\n  function getEventsForDate(store: CalendarStore, date: string): CalendarEvent[]\nCommit the file.",
      "scope": ["src/calendarService.ts"],
      "acceptance": "src/calendarService.ts exists, exports CalendarStore class and addEvent/removeEvent/getEventsForDate functions. TypeScript strict typecheck passes.",
      "checks": [
        "test -f src/calendarService.ts",
        "grep -q 'CalendarStore' src/calendarService.ts",
        "grep -q 'addEvent' src/calendarService.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create tests/calendarService.test.mjs — runtime assertions",
      "context": "Create tests/calendarService.test.mjs. Import CalendarStore from '../src/calendarService.js'.\nSince this is a NodeNext TypeScript project, the .js file won't exist until tsc compiles. Use this runtime-transpilation pattern at the top of the test file to compile the TypeScript on-the-fly:\n\n  import ts from 'typescript';\n  import { existsSync, readFileSync, writeFileSync, rmSync } from 'node:fs';\n  import { fileURLToPath } from 'node:url';\n  import path from 'node:path';\n  const __dir = path.dirname(fileURLToPath(import.meta.url));\n  for (const name of ['types', 'calendarService']) {\n    const jsf = path.join(__dir, `../src/${name}.js`);\n    const tsf = path.join(__dir, `../src/${name}.ts`);\n    if (!existsSync(jsf)) {\n      const { outputText } = ts.transpileModule(readFileSync(tsf, 'utf8'), {\n        compilerOptions: { module: ts.ModuleKind.ES2022, target: ts.ScriptTarget.ES2022 }\n      });\n      writeFileSync(jsf, outputText);\n      process.on('exit', () => rmSync(jsf, { force: true }));\n    }\n  }\n  const { CalendarStore } = await import('../src/calendarService.js');\n\nThen write assertions:\n  - Create a CalendarStore, add two events for date '2024-03-15', assert getEventsForDate returns 2 events\n  - Add a third event for a different date, assert getEventsForDate for '2024-03-15' still returns 2\n  - removeEvent the first event, assert getEventsForDate returns 1 event\n  - getAllEvents() returns the remaining 2 events\nCommit the file.",
      "scope": ["tests/calendarService.test.mjs"],
      "acceptance": "tests/calendarService.test.mjs exists with assertions for add, remove, and query. All tests pass.",
      "checks": [
        "test -f tests/calendarService.test.mjs",
        "npm test -- --runTestsByPath tests/calendarService.test.mjs"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run lint, and npm test. Fix any issues and commit if needed.",
      "scope": ["src/calendarService.ts", "tests/calendarService.test.mjs"],
      "acceptance": "Build succeeds. Lint passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run lint",
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
    "scope": "src/todoService.ts and tests/todoService.test.mjs",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create src/todoService.ts",
      "context": "Create src/todoService.ts. Import Todo and Priority from './types.js' (NodeNext requires .js extension).\nExport a TodoStore class with:\n  - private todos: Todo[] = []\n  - createTodo(todo: Todo): void\n  - completeTodo(id: string): void  — sets done = true for the matching id\n  - deleteTodo(id: string): void  — filters out the matching id\n  - filterByPriority(priority: Priority): Todo[]  — returns todos matching the priority\n  - getAllTodos(): Todo[]  — returns a copy\nCommit the file.",
      "scope": ["src/todoService.ts"],
      "acceptance": "src/todoService.ts exists, exports TodoStore with createTodo, completeTodo, deleteTodo, filterByPriority. TypeScript strict typecheck passes.",
      "checks": [
        "test -f src/todoService.ts",
        "grep -q 'TodoStore' src/todoService.ts",
        "grep -q 'createTodo' src/todoService.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create tests/todoService.test.mjs — runtime assertions",
      "context": "Create tests/todoService.test.mjs. Import TodoStore from '../src/todoService.js'.\nUse the same runtime-transpilation pattern as tests/calendarService.test.mjs: transpile 'types' and 'todoService' modules using ts.transpileModule with ModuleKind.ES2022, writing temp .js files and cleaning them up on process exit.\n\nThen write assertions:\n  - Create a TodoStore, add three todos: two with priority 'high', one with 'low'\n  - filterByPriority('high') returns 2\n  - filterByPriority('low') returns 1\n  - completeTodo on the first high-priority todo — getAllTodos shows it has done: true\n  - deleteTodo on the low-priority todo — getAllTodos returns 2 todos\nCommit the file.",
      "scope": ["tests/todoService.test.mjs"],
      "acceptance": "tests/todoService.test.mjs exists with assertions for create, complete, delete, filterByPriority. All tests pass.",
      "checks": [
        "test -f tests/todoService.test.mjs",
        "npm test -- --runTestsByPath tests/todoService.test.mjs"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run lint, and npm test. Fix any issues and commit if needed.",
      "scope": ["src/todoService.ts", "tests/todoService.test.mjs"],
      "acceptance": "Build succeeds. Lint passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run lint",
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
  "description": "Wire all modules through src/index.ts and add a cross-module integration test that uses both services together.",
  "branchName": "ralph/sprint-1/story-S-004",
  "sprint": "sprint-1",
  "priority": 4,
  "depends_on": ["S-001", "S-002", "S-003"],
  "status": "ready",
  "spec": {
    "scope": "src/index.ts and tests/integration.test.mjs",
    "preserved_invariants": [
      "APP_NAME and APP_VERSION exports must remain in src/index.ts",
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Update src/index.ts to re-export all modules",
      "context": "Update src/index.ts (which currently only exports APP_NAME and APP_VERSION). Add re-exports:\n  export * from './calendarService.js';\n  export * from './todoService.js';\n  export * from './types.js';\nKeep the existing APP_NAME and APP_VERSION exports. Commit the change.",
      "scope": ["src/index.ts"],
      "acceptance": "src/index.ts re-exports calendarService, todoService, and types. APP_NAME and APP_VERSION remain. TypeScript strict typecheck passes.",
      "checks": [
        "grep -q 'calendarService' src/index.ts",
        "grep -q 'todoService' src/index.ts",
        "grep -q 'APP_NAME' src/index.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Create tests/integration.test.mjs — cross-module assertions",
      "context": "Create tests/integration.test.mjs. This test exercises both CalendarStore and TodoStore together.\nUse the runtime-transpilation pattern: transpile 'types', 'calendarService', 'todoService', and 'index' modules using ts.transpileModule with ModuleKind.ES2022.\n\nImport CalendarStore and TodoStore from '../src/index.js' (the barrel).\n\nWrite assertions:\n  - Create a CalendarStore and add an event with id 'e1', title 'Team standup', date '2024-04-01', linkedTodoIds: ['t1']\n  - Create a TodoStore and add a todo with id 't1', title 'Prepare agenda', done: false, priority: 'high', linkedEventId: 'e1'\n  - Assert calendarStore.getEventsForDate('2024-04-01') returns 1 event with title 'Team standup'\n  - Assert todoStore.filterByPriority('high') returns 1 todo with title 'Prepare agenda'\n  - completeTodo('t1'), assert getAllTodos()[0].done === true\n  - Assert the event's linkedTodoIds includes 't1'\nCommit the file.",
      "scope": ["tests/integration.test.mjs"],
      "acceptance": "tests/integration.test.mjs exists. All cross-module assertions pass.",
      "checks": [
        "test -f tests/integration.test.mjs",
        "npm test -- --runTestsByPath tests/integration.test.mjs"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run lint, and npm test. Fix any issues and commit if needed.",
      "scope": ["src/index.ts", "tests/integration.test.mjs"],
      "acceptance": "Build succeeds. Lint passes. All tests pass including integration.",
      "checks": [
        "npm run build",
        "npm run lint",
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
npm run build && npm run lint && npm test
SH
chmod +x "$NEXTJS_DIR/scripts/ralph/ralph-sprint-test.sh"

commit_baseline "$NEXTJS_DIR" "chore(smoke): nextjs-calendar sprint plan"


# ══════════════════════════════════════════════════════════════════════════════
#  PROJECT 2: angular-calendar
#  Angular-style TypeScript: class-based services, constructor injection, Maps
# ══════════════════════════════════════════════════════════════════════════════

log "=== Setting up angular-calendar ==="

mkdir -p "$ANGULAR_DIR"
cd "$ANGULAR_DIR"
git init -b main >/dev/null
git config user.name "Ralph Smoke"
git config user.email "ralph-smoke@example.com"

cat > package.json <<'JSON'
{
  "name": "angular-calendar",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build":     "tsc -p tsconfig.json",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "lint":      "node -e \"console.log('lint ok')\"",
    "test":      "node scripts/run-tests.mjs"
  },
  "devDependencies": {
    "typescript": "^5.4.5"
  }
}
JSON

cat > tsconfig.json <<'JSON'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "experimentalDecorators": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
JSON

mkdir -p src/app/services
cat > src/index.ts <<'TS'
export const APP_NAME = "angular-calendar";
export const APP_VERSION = "0.1.0";
TS

write_run_tests_mjs "$ANGULAR_DIR"

mkdir -p tests
cat > tests/baseline.test.mjs <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
const src = readFileSync("src/index.ts", "utf8");
assert.ok(src.includes("angular-calendar"), "APP_NAME missing from src/index.ts");
JS

cat > .gitignore <<'EOF'
dist/
node_modules/
EOF

log "  npm install..."
npm install --silent
npm run build --silent

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
      "context": "Create src/app/models.ts. Export three classes:\n\n  export class CalendarEvent {\n    constructor(\n      public id: string,\n      public title: string,\n      public date: string,\n      public description: string = '',\n      public linkedTodoIds: string[] = []\n    ) {}\n  }\n\n  export class Todo {\n    public done: boolean = false;\n    constructor(\n      public id: string,\n      public title: string,\n      public priority: 'low' | 'medium' | 'high' = 'medium',\n      public dueDate?: string\n    ) {}\n  }\n\n  export class Category {\n    constructor(\n      public id: string,\n      public name: string,\n      public color: string\n    ) {}\n  }\n\nCommit the file.",
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
      "title": "Create tests/models.test.mjs — source inspection",
      "context": "Create tests/models.test.mjs. Use readFileSync to read src/app/models.ts and assert that the following class names are present: 'class CalendarEvent', 'class Todo', 'class Category'. Also assert 'linkedTodoIds' and 'priority' appear. Commit the file.",
      "scope": ["tests/models.test.mjs"],
      "acceptance": "tests/models.test.mjs exists and asserts required class names. Test passes.",
      "checks": [
        "test -f tests/models.test.mjs",
        "npm test -- --runTestsByPath tests/models.test.mjs"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run lint, and npm test. Fix any issues and commit if needed.",
      "scope": ["src/app/models.ts", "tests/models.test.mjs"],
      "acceptance": "Build succeeds. Lint passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run lint",
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
    "scope": "src/app/services/calendar.service.ts and tests/calendar.service.test.mjs",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create src/app/services/calendar.service.ts",
      "context": "Create src/app/services/calendar.service.ts. Import CalendarEvent from '../models.js' (NodeNext requires .js extension).\nExport class CalendarService with:\n  - private events: Map<string, CalendarEvent> = new Map()\n  - addEvent(event: CalendarEvent): void  — sets events.set(event.id, event)\n  - removeEvent(id: string): boolean  — returns events.delete(id)\n  - getEventsForDate(date: string): CalendarEvent[]  — filters by event.date === date\n  - getAllEvents(): CalendarEvent[]  — returns Array.from(events.values())\nCommit the file.",
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
      "title": "Create tests/calendar.service.test.mjs — runtime assertions",
      "context": "Create tests/calendar.service.test.mjs. Import CalendarService from '../src/app/services/calendar.service.js'.\nUse the runtime-transpilation pattern: for each of ['app/models', 'app/services/calendar.service'], check if the .js file exists under src/; if not, use ts.transpileModule with ModuleKind.ES2022 to compile the .ts file and write the .js file, registering process.on('exit', ...) cleanup.\n\nWrite assertions:\n  - new CalendarService(), add two CalendarEvent instances for date '2024-05-01'\n  - getEventsForDate('2024-05-01') returns array of length 2\n  - removeEvent on the first — getEventsForDate returns length 1\n  - getAllEvents() returns length 1\nCommit the file.",
      "scope": ["tests/calendar.service.test.mjs"],
      "acceptance": "tests/calendar.service.test.mjs exists with passing runtime assertions for CalendarService.",
      "checks": [
        "test -f tests/calendar.service.test.mjs",
        "npm test -- --runTestsByPath tests/calendar.service.test.mjs"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run lint, and npm test. Fix any issues and commit if needed.",
      "scope": ["src/app/services/calendar.service.ts", "tests/calendar.service.test.mjs"],
      "acceptance": "Build succeeds. Lint passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run lint",
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
    "scope": "src/app/services/todo.service.ts and tests/todo.service.test.mjs",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create src/app/services/todo.service.ts",
      "context": "Create src/app/services/todo.service.ts. Import Todo from '../models.js' (NodeNext requires .js extension).\nExport class TodoService with:\n  - private todos: Map<string, Todo> = new Map()\n  - create(todo: Todo): void  — sets todos.set(todo.id, todo)\n  - complete(id: string): void  — sets todo.done = true for the matching id\n  - delete(id: string): boolean  — returns todos.delete(id)\n  - getByPriority(priority: 'low' | 'medium' | 'high'): Todo[]  — filters by todo.priority\n  - getAll(): Todo[]  — returns Array.from(todos.values())\nCommit the file.",
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
      "title": "Create tests/todo.service.test.mjs — runtime assertions",
      "context": "Create tests/todo.service.test.mjs. Import TodoService from '../src/app/services/todo.service.js'.\nUse the runtime-transpilation pattern for ['app/models', 'app/services/todo.service'] (same as calendar.service.test.mjs).\n\nWrite assertions:\n  - new TodoService(), create three Todo instances: two with priority 'high', one with 'low'\n  - getByPriority('high') returns 2\n  - getByPriority('low') returns 1\n  - complete on the first high-priority todo — getAll() shows it has done === true\n  - delete the low-priority todo — getAll() returns 2 todos\nCommit the file.",
      "scope": ["tests/todo.service.test.mjs"],
      "acceptance": "tests/todo.service.test.mjs exists with passing runtime assertions for TodoService.",
      "checks": [
        "test -f tests/todo.service.test.mjs",
        "npm test -- --runTestsByPath tests/todo.service.test.mjs"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run lint, and npm test. Fix any issues and commit if needed.",
      "scope": ["src/app/services/todo.service.ts", "tests/todo.service.test.mjs"],
      "acceptance": "Build succeeds. Lint passes. All tests pass.",
      "checks": [
        "npm run build",
        "npm run lint",
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
  "description": "Create AppModule that wires CalendarService and TodoService as injected dependencies, and add a cross-service integration test.",
  "branchName": "ralph/sprint-1/story-S-004",
  "sprint": "sprint-1",
  "priority": 4,
  "depends_on": ["S-001", "S-002", "S-003"],
  "status": "ready",
  "spec": {
    "scope": "src/app/app.module.ts and tests/app.module.test.mjs",
    "preserved_invariants": [
      "TypeScript strict mode must remain satisfied",
      "All prior tests must continue to pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Create src/app/app.module.ts",
      "context": "Create src/app/app.module.ts. Import CalendarService from './services/calendar.service.js' and TodoService from './services/todo.service.js' (NodeNext .js extension required).\nExport:\n  export interface AppServices {\n    calendarService: CalendarService;\n    todoService: TodoService;\n  }\n  export class AppModule {\n    static create(): AppServices {\n      return {\n        calendarService: new CalendarService(),\n        todoService: new TodoService(),\n      };\n    }\n  }\nCommit the file.",
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
      "title": "Create tests/app.module.test.mjs — cross-service integration",
      "context": "Create tests/app.module.test.mjs. Use the runtime-transpilation pattern for all four modules: 'app/models', 'app/services/calendar.service', 'app/services/todo.service', 'app/app.module'.\n\nImport AppModule from '../src/app/app.module.js'.\n\nWrite assertions:\n  - const { calendarService, todoService } = AppModule.create()\n  - Both are instances of their respective classes (calendarService has addEvent, todoService has create)\n  - Add a CalendarEvent via calendarService.addEvent(...) with id 'e1', date '2024-06-01'\n  - Add a Todo via todoService.create(...) with id 't1', priority 'high'\n  - calendarService.getEventsForDate('2024-06-01') has length 1\n  - todoService.getByPriority('high') has length 1\n  - Call AppModule.create() again — assert the new instance starts with empty state (getAllEvents().length === 0)\nCommit the file.",
      "scope": ["tests/app.module.test.mjs"],
      "acceptance": "tests/app.module.test.mjs exists with passing cross-service integration assertions.",
      "checks": [
        "test -f tests/app.module.test.mjs",
        "npm test -- --runTestsByPath tests/app.module.test.mjs"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-03",
      "title": "Full regression",
      "context": "Run npm run build, npm run lint, and npm test. Fix any issues and commit if needed.",
      "scope": ["src/app/app.module.ts", "tests/app.module.test.mjs"],
      "acceptance": "Build succeeds. Lint passes. All tests pass including integration.",
      "checks": [
        "npm run build",
        "npm run lint",
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
npm run build && npm run lint && npm test
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

exit "$overall_exit"
