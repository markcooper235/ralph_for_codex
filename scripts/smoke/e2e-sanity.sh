#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./assert.sh
source "$SCRIPT_DIR/assert.sh"
# shellcheck source=./lib/token-parser.sh
source "$SCRIPT_DIR/lib/token-parser.sh"

CI_MODE=0
KEEP_REPO=0
FORCE_REAL_CODEX=0
FORCE_MOCK_CODEX=0
WITH_LOOP=0
LOOP_MODE="${LOOP_MODE:-both}"
LOOP_RETRY_MAX="${LOOP_RETRY_MAX:-2}"
LOOP_TOTAL_MAX_ITERATIONS="${LOOP_TOTAL_MAX_ITERATIONS:-10}"
APP_MODE="${APP_MODE:-console}"
BENCH_DIR="$REPO_ROOT/scripts/smoke/.benchmarks"
BENCH_FILE="$BENCH_DIR/e2e-history.tsv"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ci)
      CI_MODE=1
      shift
      ;;
    --keep)
      KEEP_REPO=1
      shift
      ;;
    --real-codex)
      FORCE_REAL_CODEX=1
      shift
      ;;
    --mock-codex)
      FORCE_MOCK_CODEX=1
      shift
      ;;
    --with-loop)
      WITH_LOOP=1
      shift
      ;;
    --with-loop-standalone)
      WITH_LOOP=1
      LOOP_MODE="standalone"
      shift
      ;;
    --with-loop-sprint)
      WITH_LOOP=1
      LOOP_MODE="sprint"
      shift
      ;;
    --loop-mode)
      [ $# -ge 2 ] || {
        echo "Missing value for --loop-mode (expected: standalone|sprint|both)" >&2
        exit 1
      }
      LOOP_MODE="$2"
      WITH_LOOP=1
      shift 2
      ;;
    --app-mode)
      [ $# -ge 2 ] || {
        echo "Missing value for --app-mode (expected: console|ui)" >&2
        exit 1
      }
      APP_MODE="$2"
      shift 2
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: scripts/smoke/e2e-sanity.sh [--ci] [--keep] [--real-codex] [--mock-codex] [--with-loop] [--loop-mode standalone|sprint|both] [--app-mode console|ui]

Runs disposable install-repo E2E sanity checks.

Options:
  --ci          CI-friendly mode (uses mock codex by default)
  --keep        Keep temp repo for debugging
  --real-codex  Force real codex binary
  --mock-codex  Force mock codex binary
  --with-loop   Run actual loops (mode defaults to both)
  --with-loop-standalone  Run only standalone loop benchmark
  --with-loop-sprint      Run only sprint story-task loop benchmark
  --loop-mode   Loop mode: standalone, sprint, or both (isolated repos per mode)
  --app-mode    App profile: console (default) or ui
USAGE
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

case "$APP_MODE" in
  console|ui) ;;
  *)
    echo "Invalid --app-mode '$APP_MODE' (expected console|ui)" >&2
    exit 1
    ;;
esac

WORK_DIR="$(mktemp -d /tmp/ralph-smoke-XXXXXX)"
TMP_HOME="$WORK_DIR/home"
TEST_REPO="$WORK_DIR/project"
mkdir -p "$TMP_HOME" "$TEST_REPO"

cleanup() {
  local exit_code=$?

  if [ "$KEEP_REPO" -eq 1 ]; then
    echo "Smoke temp repo retained: $TEST_REPO"
    return
  fi

  if [ "$exit_code" -ne 0 ]; then
    echo "[smoke] run failed; retaining temp repo for post-run reporting: $TEST_REPO"
    return
  fi

  find "$WORK_DIR" -mindepth 1 -maxdepth 5 -type f >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

extract_iteration_count_from_log() {
  local log_file="$1"
  [ -f "$log_file" ] || {
    echo 0
    return 0
  }

  awk '
    /Ralph Iteration [0-9]+ of [0-9]+/ { count += 1 }
    END { print count + 0 }
  ' "$log_file"
}

extract_completed_iteration_from_log() {
  local log_file="$1"
  [ -f "$log_file" ] || {
    echo 0
    return 0
  }

  awk '
    match($0, /Completed at iteration ([0-9]+) of [0-9]+/, m) { completed = m[1] }
    END { print completed + 0 }
  ' "$log_file"
}

append_benchmark_row() {
  local status="$1"
  mkdir -p "$BENCH_DIR"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -Iseconds)" \
    "$status" \
    "$APP_MODE" \
    "$LOOP_MODE" \
    "$standalone_planning_tokens" \
    "$((standalone_tokens-standalone_planning_tokens))" \
    "$sprint_planning_tokens" \
    "$((sprint_tokens-sprint_planning_tokens))" \
    "$standalone_iterations" \
    "$standalone_completed_iteration" \
    "$sprint_iterations" \
    "$sprint_completed_iteration" \
    >>"$BENCH_FILE"
}

run_with_retries_logged() {
  local retries="$1"
  local log_file="$2"
  local repo_root="$3"
  shift 3

  local attempt=0
  : >"$log_file"
  while true; do
    {
      echo "[smoke] attempt $((attempt + 1))/$((retries + 1))"
      echo "[smoke] cmd: $*"
    } >>"$log_file"

    if "$@" >>"$log_file" 2>&1; then
      return 0
    fi

    if [ "$attempt" -ge "$retries" ]; then
      echo "[smoke] command failed after $((attempt + 1)) attempt(s)" >>"$log_file"
      return 1
    fi

    clear_stale_workflow_lock_if_safe "$repo_root" "$log_file"
    attempt=$((attempt + 1))
    echo "[smoke] retrying..." >>"$log_file"
  done
}

clear_stale_workflow_lock_if_safe() {
  local repo_root="$1"
  local log_file="$2"
  local lock_dir="$repo_root/scripts/ralph/.workflow-lock"

  [ -d "$lock_dir" ] || return 0

  if ps -eo args= | grep -F -- "$repo_root" | grep -v grep >/dev/null 2>&1; then
    echo "[smoke] workflow lock still has active repo-scoped processes; leaving lock in place" >>"$log_file"
    return 0
  fi

  rm -rf "$lock_dir"
  echo "[smoke] removed stale workflow lock: $lock_dir" >>"$log_file"
}

assert_commit_range_small_and_simple() {
  local repo_root="$1"
  local from_ref="$2"
  local to_ref="$3"
  local label="$4"
  shift 4
  local allowed_patterns=("$@")

  local changed
  changed="$(git -C "$repo_root" diff --name-only "$from_ref..$to_ref" 2>/dev/null | sed '/^$/d' || true)"
  [ -n "$changed" ] || fail "$label produced no committed file changes."

  local bad=""
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local ok=0
    local p
    for p in "${allowed_patterns[@]}"; do
      case "$f" in
        $p)
          ok=1
          break
          ;;
      esac
    done
    if [ "$ok" -eq 0 ]; then
      bad+="$f"$'\n'
    fi
  done <<<"$changed"

  if [ -n "$bad" ]; then
    fail "$label changed files outside strict allowlist:
$bad"
  fi
}

commit_framework_baseline() {
  local repo_root="$1"
  local commit_msg="$2"

  (
    cd "$repo_root"
    git add -A
    # Ralph runtime/transient files must remain untracked.
    git reset -- scripts/ralph/prd.json scripts/ralph/progress.txt scripts/ralph/.completion-state.json >/dev/null 2>&1 || true
    if ! git diff --cached --quiet; then
      git commit -m "$commit_msg" >/dev/null
    fi
  )
}

assert_prime_log_ok() {
  local log_file="$1"
  if ! grep -qE "Primed scripts/ralph/prd.json|PRD already has unfinished stories; keeping current scripts/ralph/prd.json." "$log_file"; then
    fail "Unexpected ralph-prime output. See $log_file"
  fi
}

assert_prime_log_primed() {
  local log_file="$1"
  assert_contains "$log_file" "Primed scripts/ralph/prd.json"
}

resolve_default_base_branch() {
  local repo_root="$1"
  if git -C "$repo_root" show-ref --verify --quiet refs/heads/master; then
    echo "master"
    return 0
  fi
  if git -C "$repo_root" show-ref --verify --quiet refs/heads/main; then
    echo "main"
    return 0
  fi
  fail "Could not resolve default base branch for $repo_root (expected master or main)"
}

if [ "$FORCE_REAL_CODEX" -eq 1 ] && [ "$FORCE_MOCK_CODEX" -eq 1 ]; then
  echo "Cannot pass both --real-codex and --mock-codex" >&2
  exit 1
fi

CODEX_BIN_VALUE="codex"
if [ "$CI_MODE" -eq 1 ]; then
  CODEX_BIN_VALUE="$REPO_ROOT/scripts/smoke/mock-codex.sh"
fi
if [ "$FORCE_REAL_CODEX" -eq 1 ]; then
  CODEX_BIN_VALUE="codex"
fi
if [ "$FORCE_MOCK_CODEX" -eq 1 ]; then
  CODEX_BIN_VALUE="$REPO_ROOT/scripts/smoke/mock-codex.sh"
fi

echo "[smoke] work dir: $WORK_DIR"
echo "[smoke] codex: $CODEX_BIN_VALUE"
echo "[smoke] app mode: $APP_MODE"

echo "[smoke] running framework run-state regression test"
node --test "$REPO_ROOT/__tests__/ralph-run-state.test.js" >/dev/null

cd "$TEST_REPO"
git init -b main >/dev/null
git config user.name "Ralph Smoke"
git config user.email "ralph-smoke@example.com"

if [ "$APP_MODE" = "ui" ]; then
cat > package.json <<'JSON'
{
  "name": "ralph-smoke-ui",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "lint": "node -e \"console.log('lint ok')\"",
    "test": "node scripts/run-tests.mjs",
    "browser:check": "node scripts/browser-check.mjs"
  },
  "devDependencies": {
    "typescript": "^5.9.2",
    "playwright": "^1.53.0"
  }
}
JSON
else
cat > package.json <<'JSON'
{
  "name": "ralph-smoke-hello",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "lint": "node -e \"console.log('lint ok')\"",
    "test": "node scripts/run-tests.mjs"
  },
  "devDependencies": {
    "typescript": "^5.9.2"
  }
}
JSON
fi

if [ "$APP_MODE" = "ui" ]; then
cat > tsconfig.json <<'JSON'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "lib": ["ES2022", "DOM"],
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
JSON
else
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
fi

mkdir -p src
if [ "$APP_MODE" = "ui" ]; then
cat > src/index.ts <<'TS'
const greeting = "Hello World";
const app = document.getElementById("app");
if (app) {
  app.textContent = greeting;
}
console.log(greeting);
TS

cat > index.html <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Ralph Smoke UI</title>
</head>
<body>
  <main>
    <h1 id="app"></h1>
  </main>
  <script type="module" src="./dist/index.js"></script>
</body>
</html>
HTML
else
cat > src/index.ts <<'TS'
console.log("Hello World");
TS
fi

mkdir -p scripts
cat > scripts/run-tests.mjs <<'JS'
import assert from "node:assert/strict";
import { readdirSync, statSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const argv = process.argv.slice(2);
let runTestsByPath = [];
let testPathIgnorePatterns = "";

for (let i = 0; i < argv.length; i += 1) {
  const arg = argv[i];
  if (arg === "--runTestsByPath") {
    i += 1;
    while (i < argv.length && !argv[i].startsWith("--")) {
      runTestsByPath.push(argv[i]);
      i += 1;
    }
    i -= 1;
    continue;
  }
  if (arg === "--testPathIgnorePatterns") {
    if (i + 1 < argv.length) {
      testPathIgnorePatterns = argv[i + 1];
      i += 1;
    }
    continue;
  }
}

function collectTests(dir) {
  const entries = readdirSync(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...collectTests(full));
      continue;
    }
    if (/(\.test|\.spec)\.m?js$/.test(entry.name)) {
      files.push(full);
    }
  }
  return files;
}

let tests = [];
if (runTestsByPath.length > 0) {
  tests = runTestsByPath.map((p) => path.resolve(p));
} else if (statSync("tests").isDirectory()) {
  tests = collectTests("tests").map((p) => path.resolve(p));
}

if (testPathIgnorePatterns) {
  const ignoreRe = new RegExp(testPathIgnorePatterns);
  tests = tests.filter((p) => !ignoreRe.test(p));
}

assert.ok(tests.length > 0, "No tests discovered");
for (const testPath of tests) {
  await import(pathToFileURL(testPath).href);
}

console.log(`PASS ${tests.length} test file(s)`);
console.log("test ok");
JS

if [ "$APP_MODE" = "ui" ]; then
cat > scripts/browser-check.mjs <<'JS'
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { chromium } from "playwright";

const expected = process.argv[2] || "Hello World";
const MIME_TYPES = new Map([
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"]
]);

function contentTypeFor(pathname) {
  const idx = pathname.lastIndexOf(".");
  if (idx === -1) return "text/plain; charset=utf-8";
  return MIME_TYPES.get(pathname.slice(idx)) || "text/plain; charset=utf-8";
}

const server = createServer(async (req, res) => {
  const pathname = req.url === "/" ? "/index.html" : (req.url || "/index.html");
  const filePath = `.${pathname}`;
  try {
    const body = await readFile(filePath);
    res.writeHead(200, { "content-type": contentTypeFor(pathname) });
    res.end(body);
  } catch {
    res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    res.end("not found");
  }
});

await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(0, "127.0.0.1", resolve);
});
const address = server.address();
if (!address || typeof address === "string") {
  throw new Error("Failed to resolve local server address");
}
const baseUrl = `http://127.0.0.1:${address.port}`;

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
await page.goto(`${baseUrl}/index.html`);
await page.waitForFunction(() => {
  const el = document.querySelector("#app");
  return !!el && (el.textContent || "").trim().length > 0;
});
const text = await page.textContent("#app");
assert.equal((text || "").trim(), expected, `Expected #app to equal '${expected}'`);
await browser.close();
server.close();
console.log(`browser ok: ${expected}`);
JS
fi

mkdir -p tests
cat > tests/hello.test.mjs <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync("src/index.ts", "utf8");
assert.match(source, /Hello World/, "Expected baseline greeting in src/index.ts");
JS

cat > .gitignore <<'EOF'
dist/
EOF

npm install --silent
npm run build --silent

git add .
git reset dist >/dev/null 2>&1 || true
git commit -m "chore: init smoke hello world" >/dev/null

echo "[smoke] refresh skills"
HOME="$TMP_HOME" "$REPO_ROOT/install.sh" --install-skills > "$WORK_DIR/install-skills.log" 2>&1
assert_contains "$WORK_DIR/install-skills.log" "Installed Codex skill: prd"
assert_file_exists "$TMP_HOME/.codex/skills/prd/SKILL.md"
assert_file_exists "$TMP_HOME/.codex/skills/ralph/SKILL.md"
assert_file_exists "$TMP_HOME/.codex/skills/setup/SKILL.md"


echo "[smoke] install framework"
HOME="$TMP_HOME" "$REPO_ROOT/install.sh" --project "$TEST_REPO" --no-example-prd > "$WORK_DIR/install-framework.log" 2>&1
assert_file_exists "$TEST_REPO/scripts/ralph/doctor.sh"
assert_file_exists "$TEST_REPO/scripts/ralph/ralph-story.sh"
assert_file_exists "$TEST_REPO/scripts/ralph/ralph-task.sh"
assert_file_exists "$TEST_REPO/scripts/ralph/ralph-prd.sh"
commit_framework_baseline "$TEST_REPO" "chore: install ralph framework baseline"


echo "[smoke] doctor"
if [ "$WITH_LOOP" -eq 0 ]; then
  (
    cd "$TEST_REPO/scripts/ralph"
    CODEX_BIN="$CODEX_BIN_VALUE" ./doctor.sh > "$WORK_DIR/doctor.log" 2>&1
  )
  assert_contains "$WORK_DIR/doctor.log" "OK: prerequisites present"
else
  echo "[smoke] skipping global doctor in loop mode (mode-specific doctors run in isolated repos)"
fi

if [ "$WITH_LOOP" -eq 1 ]; then
  case "$LOOP_MODE" in
    standalone|sprint|both) ;;
    *)
      fail "Invalid loop mode '$LOOP_MODE' (expected standalone|sprint|both)"
      ;;
  esac

  echo "[smoke] loop checks (standalone + sprint story-task)"
  if [ "$CODEX_BIN_VALUE" != "codex" ]; then
    echo "[smoke] --with-loop requested with non-real codex; forcing real codex for loop phase"
  fi
  LOOP_CODEX_BIN="codex"
  LOOP_STANDALONE_MAX_ITERATIONS="$LOOP_TOTAL_MAX_ITERATIONS"
  echo "[smoke] loop config: max_iterations=$LOOP_TOTAL_MAX_ITERATIONS retry_max=$LOOP_RETRY_MAX"

  STANDALONE_REPO="$WORK_DIR/project-loop-standalone"
  SPRINT_REPO="$WORK_DIR/project-loop-sprint"
  cp -a "$TEST_REPO" "$STANDALONE_REPO"
  cp -a "$TEST_REPO" "$SPRINT_REPO"
  echo "[smoke] isolated repos: standalone=$STANDALONE_REPO sprint=$SPRINT_REPO"

  standalone_tokens=0
  sprint_tokens=0
  standalone_planning_tokens=0
  sprint_planning_tokens=0
  standalone_iterations=0
  sprint_iterations=0
  standalone_completed_iteration=0
  sprint_completed_iteration=0

  if [ "$LOOP_MODE" = "standalone" ] || [ "$LOOP_MODE" = "both" ]; then
    standalone_expected_target="$(resolve_default_base_branch "$STANDALONE_REPO")"
    standalone_expected_msg="Hello PRD Ralph"
    if [ "$APP_MODE" = "ui" ]; then
      standalone_feature_text="Change UI greeting message to Hello PRD Ralph"
      standalone_constraints_text="Keep implementation changes limited to src/index.ts and tests/hello.test.mjs only. Ensure browser output in #app is Hello PRD Ralph."
    else
      standalone_feature_text="Change hello message to Hello PRD Ralph"
      standalone_constraints_text="Keep implementation changes limited to src/index.ts and tests/hello.test.mjs only"
    fi
    (
      cd "$STANDALONE_REPO/scripts/ralph"
      CODEX_BIN="$CODEX_BIN_VALUE" ./doctor.sh > "$WORK_DIR/doctor-standalone.log" 2>&1
      CODEX_BIN="$CODEX_BIN_VALUE" ./ralph-prd.sh \
        --feature "$standalone_feature_text" \
        --constraints "$standalone_constraints_text" \
        --no-questions > "$WORK_DIR/ralph-prd-standalone.log" 2>&1
      commit_framework_baseline "$STANDALONE_REPO" "chore(smoke): pre-loop planning state (standalone)"
      standalone_start_head="$(git -C "$STANDALONE_REPO" rev-parse HEAD)"
      run_with_retries_logged "$LOOP_RETRY_MAX" "$WORK_DIR/loop-standalone.log" "$STANDALONE_REPO" timeout 420 env CODEX_BIN="$LOOP_CODEX_BIN" ./ralph.sh "$LOOP_STANDALONE_MAX_ITERATIONS"
      standalone_end_head="$(git -C "$STANDALONE_REPO" rev-parse HEAD)"
      [ ! -e .codex-last-message.txt ] || fail "standalone loop should not leave legacy .codex-last-message.txt"
      if find . -maxdepth 1 -name '.codex-last-message*' | grep -q .; then
        fail "standalone loop should not create legacy .codex-last-message artifacts"
      fi
      jq -e '.completionSignal == true and .status == "completed"' .iteration-handoff-latest.json >/dev/null
      jq -e '.completionSignal == true and .status == "completed"' .completion-state.json >/dev/null
      jq -e 'all(.userStories[]; .passes == true)' prd.json >/dev/null
      assert_commit_range_small_and_simple "$STANDALONE_REPO" "$standalone_start_head" "$standalone_end_head" "standalone loop" "src/index.ts" "tests/hello.test.mjs"
      if [ "$APP_MODE" = "ui" ]; then
        grep -qF "const greeting = \"$standalone_expected_msg\";" "$STANDALONE_REPO/src/index.ts" || fail "standalone src/index.ts does not contain expected UI greeting assignment: $standalone_expected_msg"
      else
        grep -qF "console.log(\"$standalone_expected_msg\");" "$STANDALONE_REPO/src/index.ts" || fail "standalone src/index.ts does not contain expected greeting: $standalone_expected_msg"
      fi
      grep -qF "$standalone_expected_msg" "$STANDALONE_REPO/tests/hello.test.mjs" || fail "standalone tests/hello.test.mjs missing expected greeting assertion text: $standalone_expected_msg"
      (
        cd "$STANDALONE_REPO"
        npm run -s build > "$WORK_DIR/build-standalone.log" 2>&1
        npm test > "$WORK_DIR/test-standalone.log" 2>&1
        if [ "$APP_MODE" = "ui" ]; then
          npm run -s browser:check -- "$standalone_expected_msg" > "$WORK_DIR/runtime-standalone.log" 2>&1
        else
          node dist/index.js > "$WORK_DIR/runtime-standalone.log" 2>&1
        fi
        if git ls-files --error-unmatch dist/index.js >/dev/null 2>&1; then
          git checkout -- dist/index.js
        fi
      )
      ./ralph-commit.sh --dry-run > "$WORK_DIR/commit-plan-standalone-default.log" 2>&1
      ./ralph-commit.sh --dry-run --target "$standalone_expected_target" > "$WORK_DIR/commit-plan-standalone-target.log" 2>&1
      ./ralph-commit.sh > "$WORK_DIR/commit-standalone.log" 2>&1
      [ ! -s prd.json ] || fail "standalone post-commit prd.json should be emptied by archive flow"
      git -C "$STANDALONE_REPO" ls-files --error-unmatch scripts/ralph/prd.json >/dev/null 2>&1 && fail "standalone post-commit prd.json must be untracked"
      git -C "$STANDALONE_REPO" ls-files --error-unmatch scripts/ralph/progress.txt >/dev/null 2>&1 && fail "standalone post-commit progress.txt must be untracked"
      git -C "$STANDALONE_REPO" ls-files --error-unmatch scripts/ralph/.completion-state.json >/dev/null 2>&1 && fail "standalone post-commit .completion-state.json must be untracked"
      ./ralph-sprint.sh status > "$WORK_DIR/status-standalone-postcommit.log" 2>&1 || true
    )
    assert_contains "$WORK_DIR/doctor-standalone.log" "OK: prerequisites present"
    assert_not_contains "$WORK_DIR/ralph-prd-standalone.log" "No PRD markdown file"
    assert_contains "$WORK_DIR/loop-standalone.log" "Iteration"
    assert_not_contains "$WORK_DIR/loop-standalone.log" "node: bad option: --runInBand"
    if [ "$APP_MODE" = "console" ]; then
      if ! grep -Eq "Create a compact Ralph planning package for a tightly scoped change\.|Using compact planning mode for a tightly scoped request\." "$WORK_DIR/ralph-prd-standalone.log"; then
        fail "Expected compact planning evidence in $WORK_DIR/ralph-prd-standalone.log"
      fi
    else
      assert_not_contains "$WORK_DIR/ralph-prd-standalone.log" "Create a compact Ralph planning package for a tightly scoped change\."
      assert_not_contains "$WORK_DIR/ralph-prd-standalone.log" "Using compact planning mode for a tightly scoped request\."
    fi
    if [ "$APP_MODE" = "ui" ]; then
      assert_contains "$WORK_DIR/runtime-standalone.log" "browser ok: $standalone_expected_msg"
    else
      assert_contains "$WORK_DIR/runtime-standalone.log" "^$standalone_expected_msg$"
    fi
    assert_contains "$WORK_DIR/test-standalone.log" "test ok"
    standalone_planning_tokens="$(extract_tokens_from_log "$WORK_DIR/ralph-prd-standalone.log")"
    assert_contains "$WORK_DIR/commit-plan-standalone-default.log" "target branch:  $standalone_expected_target"
    assert_contains "$WORK_DIR/commit-plan-standalone-target.log" "target branch:  $standalone_expected_target"
    assert_contains "$WORK_DIR/commit-plan-standalone-default.log" "prd mode:       standalone"
    assert_contains "$WORK_DIR/commit-plan-standalone-default.log" "prd base:       $standalone_expected_target"
    assert_contains "$WORK_DIR/commit-standalone.log" "Deleted source branch:"
    standalone_tokens="$(extract_tokens_from_log "$WORK_DIR/loop-standalone.log")"
    standalone_tokens=$((standalone_tokens + standalone_planning_tokens))
    standalone_iterations="$(extract_iteration_count_from_log "$WORK_DIR/loop-standalone.log")"
    standalone_completed_iteration="$(extract_completed_iteration_from_log "$WORK_DIR/loop-standalone.log")"
  fi

  if [ "$LOOP_MODE" = "sprint" ] || [ "$LOOP_MODE" = "both" ]; then
    sprint_expected_target="ralph/sprint/sprint-1"
    sprint_expected_msg="Hello Sprint Ralph"
    if [ "$APP_MODE" = "ui" ]; then
      sprint_story_title="Update UI greeting string and unit test"
      sprint_task_t01_context="Update src/index.ts UI greeting constant to exactly Hello Sprint Ralph. The current value is Hello World. Change only the greeting string, keep all other code unchanged. Commit the change."
      sprint_task_t01_acceptance="src/index.ts contains Hello Sprint Ralph as the greeting value. Typecheck passes."
      sprint_task_t02_context="Update tests/hello.test.mjs assertion to expect Hello Sprint Ralph instead of Hello World. Change only the assertion string. Commit the change."
      sprint_task_t02_acceptance="tests/hello.test.mjs asserts Hello Sprint Ralph. All tests pass."
    else
      sprint_story_title="Update greeting string and unit test"
      sprint_task_t01_context="Update src/index.ts to print exactly Hello Sprint Ralph instead of Hello World. Change only the greeting string in the console.log call. Commit the change."
      sprint_task_t01_acceptance="src/index.ts contains Hello Sprint Ralph in the console.log statement. Typecheck passes."
      sprint_task_t02_context="Update tests/hello.test.mjs assertion to expect Hello Sprint Ralph instead of Hello World. Change only the assertion string. Commit the change."
      sprint_task_t02_acceptance="tests/hello.test.mjs asserts Hello Sprint Ralph. All tests pass."
    fi
    (
      cd "$SPRINT_REPO/scripts/ralph"
      CODEX_BIN="$CODEX_BIN_VALUE" ./doctor.sh > "$WORK_DIR/doctor-sprint.log" 2>&1
      ./ralph-sprint.sh remove sprint-1 --yes --hard > "$WORK_DIR/sprint-reset-sprint.log" 2>&1 || true
      RALPH_EDITOR=true ./ralph-sprint.sh create sprint-1 > "$WORK_DIR/sprint-create-sprint.log" 2>&1 </dev/null
      ./ralph-story.sh add \
        --title "$sprint_story_title" \
        --goal "Update the app greeting to Hello Sprint Ralph and update tests accordingly." \
        --prompt-context "Change the greeting string in src/index.ts and update the assertion in tests/hello.test.mjs." \
        > "$WORK_DIR/story-add-sprint.log" 2>&1
      mkdir -p "sprints/sprint-1/stories/S-001"
      cat > "sprints/sprint-1/stories/S-001/story.json" <<STORYJSON
{
  "version": 1,
  "project": "smoke",
  "storyId": "S-001",
  "title": "$sprint_story_title",
  "description": "Update greeting in src/index.ts to Hello Sprint Ralph and update tests accordingly.",
  "branchName": "ralph/sprint-1/story-S-001",
  "sprint": "sprint-1",
  "priority": 1,
  "depends_on": [],
  "status": "active",
  "spec": {
    "scope": "Update greeting string in src/index.ts and test assertion in tests/hello.test.mjs.",
    "preserved_invariants": [
      "All existing tests must pass after changes",
      "TypeScript typecheck must pass"
    ]
  },
  "tasks": [
    {
      "id": "T-01",
      "title": "Update greeting in src/index.ts",
      "context": "$sprint_task_t01_context",
      "scope": ["src/index.ts"],
      "acceptance": "$sprint_task_t01_acceptance",
      "checks": [
        "grep -q 'Hello Sprint Ralph' src/index.ts",
        "npm run typecheck"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    },
    {
      "id": "T-02",
      "title": "Update test assertion in tests/hello.test.mjs",
      "context": "$sprint_task_t02_context",
      "scope": ["tests/hello.test.mjs"],
      "acceptance": "$sprint_task_t02_acceptance",
      "checks": [
        "grep -q 'Hello Sprint Ralph' tests/hello.test.mjs",
        "npm test"
      ],
      "depends_on": [],
      "status": "pending",
      "passes": false
    }
  ],
  "passes": false
}
STORYJSON
      ./ralph-story.sh start-next > "$WORK_DIR/story-start-sprint.log" 2>&1
      ./ralph-sprint.sh status > "$WORK_DIR/status-sprint-preloop.log" 2>&1 || true
      commit_framework_baseline "$SPRINT_REPO" "chore(smoke): pre-loop planning state (sprint)"
      sprint_loop_start_head="$(git -C "$SPRINT_REPO" rev-parse HEAD)"
      run_with_retries_logged "$LOOP_RETRY_MAX" "$WORK_DIR/loop-sprint.log" "$SPRINT_REPO" timeout 420 env CODEX_BIN="$LOOP_CODEX_BIN" ./ralph-task.sh
      sprint_loop_end_head="$(git -C "$SPRINT_REPO" rev-parse HEAD)"
      jq -e '.passes == true and .status == "done"' "sprints/sprint-1/stories/S-001/story.json" >/dev/null
      jq -e '[.stories[] | select(.id == "S-001")] | .[0].status == "done" and .[0].passes == true' "sprints/sprint-1/stories.json" >/dev/null
      assert_commit_range_small_and_simple "$SPRINT_REPO" "$sprint_loop_start_head" "$sprint_loop_end_head" "sprint loop" "src/index.ts" "tests/hello.test.mjs"
      if [ "$APP_MODE" = "ui" ]; then
        grep -qF "const greeting = \"$sprint_expected_msg\";" "$SPRINT_REPO/src/index.ts" || fail "sprint src/index.ts does not contain expected UI greeting assignment: $sprint_expected_msg"
      else
        grep -qF "console.log(\"$sprint_expected_msg\");" "$SPRINT_REPO/src/index.ts" || fail "sprint src/index.ts does not contain expected greeting: $sprint_expected_msg"
      fi
      grep -qF "$sprint_expected_msg" "$SPRINT_REPO/tests/hello.test.mjs" || fail "sprint tests/hello.test.mjs missing expected greeting assertion text: $sprint_expected_msg"
      (
        cd "$SPRINT_REPO"
        npm run -s build > "$WORK_DIR/build-sprint.log" 2>&1
        npm test > "$WORK_DIR/test-sprint.log" 2>&1
        if [ "$APP_MODE" = "ui" ]; then
          npm run -s browser:check -- "$sprint_expected_msg" > "$WORK_DIR/runtime-sprint.log" 2>&1
        else
          node dist/index.js > "$WORK_DIR/runtime-sprint.log" 2>&1
        fi
        if git ls-files --error-unmatch dist/index.js >/dev/null 2>&1; then
          git checkout -- dist/index.js
        fi
      )
      ./ralph-sprint-commit.sh > "$WORK_DIR/sprint-commit-sprint.log" 2>&1
    )
    assert_contains "$WORK_DIR/doctor-sprint.log" "OK: prerequisites present"
    assert_contains "$WORK_DIR/sprint-create-sprint.log" "Created sprint: sprint-1"
    assert_contains "$WORK_DIR/story-add-sprint.log" "Added story: S-001"
    assert_contains "$WORK_DIR/story-start-sprint.log" "Started story: S-001"
    assert_contains "$WORK_DIR/loop-sprint.log" "Task T-01"
    assert_contains "$WORK_DIR/loop-sprint.log" "Story S-001 COMPLETE"
    assert_not_contains "$WORK_DIR/loop-sprint.log" "node: bad option: --runInBand"
    if [ "$APP_MODE" = "ui" ]; then
      assert_contains "$WORK_DIR/runtime-sprint.log" "browser ok: $sprint_expected_msg"
    else
      assert_contains "$WORK_DIR/runtime-sprint.log" "^$sprint_expected_msg$"
    fi
    assert_contains "$WORK_DIR/test-sprint.log" "test ok"
    assert_contains "$WORK_DIR/sprint-commit-sprint.log" "Deleted source sprint branch:"
    sprint_tokens="$(extract_tokens_from_log "$WORK_DIR/loop-sprint.log")"
    sprint_planning_tokens=0
    sprint_iterations="$(extract_iteration_count_from_log "$WORK_DIR/loop-sprint.log")"
    sprint_completed_iteration="$(extract_completed_iteration_from_log "$WORK_DIR/loop-sprint.log")"
  fi

  total_tokens=$((standalone_tokens + sprint_tokens))
  if [ "$standalone_tokens" -eq 0 ] && [ "$sprint_tokens" -eq 0 ]; then
    echo "[smoke] token summary: unavailable (no 'tokens used' markers emitted by codex output)"
  else
    echo "[smoke] token summary (planning+loop): app_mode=$APP_MODE mode=$LOOP_MODE standalone=$standalone_tokens sprint=$sprint_tokens total=$total_tokens"
    echo "[smoke] token detail: standalone_planning=$standalone_planning_tokens standalone_loop=$((standalone_tokens-standalone_planning_tokens)) sprint_planning=$sprint_planning_tokens sprint_loop=$((sprint_tokens-sprint_planning_tokens))"
    echo "[smoke] loop detail: standalone_iterations=$standalone_iterations standalone_completed_iteration=$standalone_completed_iteration sprint_iterations=$sprint_iterations sprint_completed_iteration=$sprint_completed_iteration"
    append_benchmark_row "pass"
  fi
fi


echo "[smoke] PASS: install-repo E2E sanity checks completed"
