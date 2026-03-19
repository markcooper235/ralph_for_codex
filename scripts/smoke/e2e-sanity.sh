#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./assert.sh
source "$SCRIPT_DIR/assert.sh"

CI_MODE=0
KEEP_REPO=0
FORCE_REAL_CODEX=0
FORCE_MOCK_CODEX=0
WITH_LOOP=0
LOOP_MODE="${LOOP_MODE:-both}"
LOOP_RETRY_MAX="${LOOP_RETRY_MAX:-2}"
LOOP_TOTAL_MAX_ITERATIONS="${LOOP_TOTAL_MAX_ITERATIONS:-10}"
APP_MODE="${APP_MODE:-console}"

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
    --with-loop-epic)
      WITH_LOOP=1
      LOOP_MODE="epic"
      shift
      ;;
    --loop-mode)
      [ $# -ge 2 ] || {
        echo "Missing value for --loop-mode (expected: standalone|epic|both)" >&2
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
Usage: scripts/smoke/e2e-sanity.sh [--ci] [--keep] [--real-codex] [--mock-codex] [--with-loop] [--loop-mode standalone|epic|both] [--app-mode console|ui]

Runs disposable install-repo E2E sanity checks.

Options:
  --ci          CI-friendly mode (uses mock codex by default)
  --keep        Keep temp repo for debugging
  --real-codex  Force real codex binary
  --mock-codex  Force mock codex binary
  --with-loop   Run actual ralph.sh loops (mode defaults to both)
  --with-loop-standalone  Run only standalone loop benchmark
  --with-loop-epic        Run only sprint-epic loop benchmark
  --loop-mode   Loop mode: standalone, epic, or both (isolated repos per mode)
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

extract_tokens_from_log() {
  local log_file="$1"
  [ -f "$log_file" ] || {
    echo 0
    return 0
  }

  awk '
    {
      line = $0
      lower = tolower(line)
      gsub(/,/, "", line)
      gsub(/,/, "", lower)

      if (pending_tokens_used == 1) {
        if (match(line, /([0-9]+)/, m)) {
          sum += m[1]
        }
        pending_tokens_used = 0
      }

      if (match(lower, /tokens used[[:space:]]*([0-9]+)/, m)) {
        sum += m[1]
        next
      }
      if (lower ~ /tokens used/) {
        pending_tokens_used = 1
        next
      }

      if (match(lower, /"total_tokens"[[:space:]]*:[[:space:]]*([0-9]+)/, m)) {
        sum += m[1]
        next
      }
      if (match(lower, /total tokens[[:space:]]*[:=]?[[:space:]]*([0-9]+)/, m)) {
        sum += m[1]
        next
      }
    }
    END {
      print sum + 0
    }
  ' "$log_file"
}

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

run_with_retries_logged() {
  local retries="$1"
  local log_file="$2"
  shift 2

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

    attempt=$((attempt + 1))
    echo "[smoke] retrying..." >>"$log_file"
  done
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
    git reset -- scripts/ralph/prd.json scripts/ralph/progress.txt >/dev/null 2>&1 || true
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
assert_file_exists "$TEST_REPO/scripts/ralph/ralph-epic.sh"
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
    standalone|epic|both) ;;
    *)
      fail "Invalid loop mode '$LOOP_MODE' (expected standalone|epic|both)"
      ;;
  esac

  echo "[smoke] loop checks (standalone + sprint epic)"
  if [ "$CODEX_BIN_VALUE" != "codex" ]; then
    echo "[smoke] --with-loop requested with non-real codex; forcing real codex for loop phase"
  fi
  LOOP_CODEX_BIN="codex"
  LOOP_STANDALONE_MAX_ITERATIONS="$LOOP_TOTAL_MAX_ITERATIONS"
  LOOP_EPIC_MAX_ITERATIONS="$LOOP_TOTAL_MAX_ITERATIONS"
  echo "[smoke] loop config: max_iterations=$LOOP_TOTAL_MAX_ITERATIONS retry_max=$LOOP_RETRY_MAX"

  STANDALONE_REPO="$WORK_DIR/project-loop-standalone"
  EPIC_REPO="$WORK_DIR/project-loop-epic"
  cp -a "$TEST_REPO" "$STANDALONE_REPO"
  cp -a "$TEST_REPO" "$EPIC_REPO"
  echo "[smoke] isolated repos: standalone=$STANDALONE_REPO epic=$EPIC_REPO"

  standalone_tokens=0
  epic_tokens=0
  standalone_planning_tokens=0
  epic_planning_tokens=0
  standalone_iterations=0
  epic_iterations=0
  standalone_completed_iteration=0
  epic_completed_iteration=0

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
      ./ralph-prime.sh --auto > "$WORK_DIR/prime-standalone.log" 2>&1 || true
      commit_framework_baseline "$STANDALONE_REPO" "chore(smoke): pre-loop planning state (standalone)"
      standalone_start_head="$(git -C "$STANDALONE_REPO" rev-parse HEAD)"
      run_with_retries_logged "$LOOP_RETRY_MAX" "$WORK_DIR/loop-standalone.log" timeout 420 env CODEX_BIN="$LOOP_CODEX_BIN" ./ralph.sh "$LOOP_STANDALONE_MAX_ITERATIONS"
      standalone_end_head="$(git -C "$STANDALONE_REPO" rev-parse HEAD)"
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
      ./ralph-sprint.sh status > "$WORK_DIR/status-standalone-postcommit.log" 2>&1 || true
    )
    assert_contains "$WORK_DIR/doctor-standalone.log" "OK: prerequisites present"
    assert_not_contains "$WORK_DIR/ralph-prd-standalone.log" "No PRD markdown file"
    assert_prime_log_ok "$WORK_DIR/prime-standalone.log"
    assert_contains "$WORK_DIR/loop-standalone.log" "Iteration"
    assert_not_contains "$WORK_DIR/loop-standalone.log" "node: bad option: --runInBand"
    if [ "$APP_MODE" = "ui" ]; then
      assert_contains "$WORK_DIR/runtime-standalone.log" "browser ok: $standalone_expected_msg"
    else
      assert_contains "$WORK_DIR/runtime-standalone.log" "^$standalone_expected_msg$"
    fi
    assert_contains "$WORK_DIR/test-standalone.log" "test ok"
    standalone_planning_tokens=$(( $(extract_tokens_from_log "$WORK_DIR/ralph-prd-standalone.log") + $(extract_tokens_from_log "$WORK_DIR/prime-standalone.log") ))
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

  if [ "$LOOP_MODE" = "epic" ] || [ "$LOOP_MODE" = "both" ]; then
    epic_expected_target="ralph/sprint/sprint-1"
    epic_expected_msg="Hello Sprint Ralph"
    if [ "$APP_MODE" = "ui" ]; then
      epic_prompt_context="Change UI output greeting to Hello Sprint Ralph in src/index.ts, update tests/hello.test.mjs assertion accordingly, and verify browser #app output."
      epic_story_title="Update UI greeting string and unit test"
      epic_story_desc="Update src/index.ts UI greeting output to exactly Hello Sprint Ralph and update tests/hello.test.mjs assertion accordingly."
      epic_story_ac='["Update src/index.ts to set #app text to exactly Hello Sprint Ralph.","Update tests/hello.test.mjs assertion to verify Hello Sprint Ralph.","Verify browser #app output is Hello Sprint Ralph.","Typecheck passes","Lint passes","Unit tests pass"]'
    else
      epic_prompt_context="Change output greeting to Hello Sprint Ralph in src/index.ts and update tests/hello.test.mjs assertion accordingly."
      epic_story_title="Update greeting string and unit test"
      epic_story_desc="Update src/index.ts greeting output to exactly Hello Sprint Ralph and update tests/hello.test.mjs assertion accordingly."
      epic_story_ac='["Update src/index.ts to print exactly Hello Sprint Ralph.","Update tests/hello.test.mjs assertion to verify Hello Sprint Ralph.","Typecheck passes","Lint passes","Unit tests pass"]'
    fi
    (
      cd "$EPIC_REPO/scripts/ralph"
      CODEX_BIN="$CODEX_BIN_VALUE" ./doctor.sh > "$WORK_DIR/doctor-epic.log" 2>&1
      ./ralph-sprint.sh remove sprint-1 --yes --hard > "$WORK_DIR/sprint-reset-epic.log" 2>&1 || true
      RALPH_EDITOR=true ./ralph-sprint.sh create sprint-1 > "$WORK_DIR/sprint-create-epic.log" 2>&1 </dev/null
      ./ralph-epic.sh add \
        --title "Change Hello Message: Hello Sprint Ralph" \
        --status planned \
        --prompt-context "$epic_prompt_context" \
        > "$WORK_DIR/epic-add-epic.log" 2>&1
      ./ralph-sprint.sh use sprint-1 > "$WORK_DIR/sprint-use-loop.log" 2>&1
      ./ralph-epic.sh start-next > "$WORK_DIR/epic-start-loop.log" 2>&1
      : > prd.json
      run_with_retries_logged "$LOOP_RETRY_MAX" "$WORK_DIR/prime-epic.log" timeout 300 env CODEX_BIN="$LOOP_CODEX_BIN" ./ralph-prime.sh --auto
      jq --arg title "$epic_story_title" --arg desc "$epic_story_desc" --argjson ac "$epic_story_ac" '.branchName = "ralph/epic-001" | .userStories = [(.userStories[0] | .id="US-001" | .title=$title | .description=$desc | .acceptanceCriteria=$ac | .priority=1 | .passes=false | .notes="")]' prd.json > /tmp/smoke-prd.json
      mv /tmp/smoke-prd.json prd.json
      ./ralph-sprint.sh status > "$WORK_DIR/status-epic-preloop.log" 2>&1 || true
      commit_framework_baseline "$EPIC_REPO" "chore(smoke): pre-loop planning state (epic)"
      active_sprint_id="$(cat .active-sprint 2>/dev/null || echo sprint-1)"
      active_epics_rel="scripts/ralph/sprints/$active_sprint_id/epics.json"
      if git -C "$EPIC_REPO" ls-files --error-unmatch "$active_epics_rel" >/dev/null 2>&1 && ! git -C "$EPIC_REPO" diff --quiet -- "$active_epics_rel"; then
        git -C "$EPIC_REPO" add "$active_epics_rel"
        git -C "$EPIC_REPO" commit -m "chore(smoke): sync active epic backlog before loop" >/dev/null
      fi
      epic_loop_start_head="$(git -C "$EPIC_REPO" rev-parse HEAD)"
      run_with_retries_logged "$LOOP_RETRY_MAX" "$WORK_DIR/loop-epic.log" timeout 420 env CODEX_BIN="$LOOP_CODEX_BIN" ./ralph.sh "$LOOP_EPIC_MAX_ITERATIONS"
      epic_loop_end_head="$(git -C "$EPIC_REPO" rev-parse HEAD)"
      jq -e '.branchName | test("^ralph/.+/epic-[0-9]+$") or test("^ralph/epic-[0-9]+$")' prd.json >/dev/null
      jq -e '([.userStories[] | select(.passes == true)] | length) >= 1' prd.json >/dev/null
      assert_commit_range_small_and_simple "$EPIC_REPO" "$epic_loop_start_head" "$epic_loop_end_head" "epic loop" "src/index.ts" "tests/hello.test.mjs"
      if [ "$APP_MODE" = "ui" ]; then
        grep -qF "const greeting = \"$epic_expected_msg\";" "$EPIC_REPO/src/index.ts" || fail "epic src/index.ts does not contain expected UI greeting assignment: $epic_expected_msg"
      else
        grep -qF "console.log(\"$epic_expected_msg\");" "$EPIC_REPO/src/index.ts" || fail "epic src/index.ts does not contain expected greeting: $epic_expected_msg"
      fi
      grep -qF "$epic_expected_msg" "$EPIC_REPO/tests/hello.test.mjs" || fail "epic tests/hello.test.mjs missing expected greeting assertion text: $epic_expected_msg"
      (
        cd "$EPIC_REPO"
        npm run -s build > "$WORK_DIR/build-epic.log" 2>&1
        npm test > "$WORK_DIR/test-epic.log" 2>&1
        if [ "$APP_MODE" = "ui" ]; then
          npm run -s browser:check -- "$epic_expected_msg" > "$WORK_DIR/runtime-epic.log" 2>&1
        else
          node dist/index.js > "$WORK_DIR/runtime-epic.log" 2>&1
        fi
        if git ls-files --error-unmatch dist/index.js >/dev/null 2>&1; then
          git checkout -- dist/index.js
        fi
      )
      ./ralph-commit.sh --dry-run > "$WORK_DIR/commit-plan-epic-default.log" 2>&1
      ./ralph-commit.sh --dry-run --target "$epic_expected_target" > "$WORK_DIR/commit-plan-epic-target.log" 2>&1
      ./ralph-commit.sh > "$WORK_DIR/commit-epic.log" 2>&1
      [ ! -s prd.json ] || fail "epic post-commit prd.json should be emptied by archive flow"
      git -C "$EPIC_REPO" ls-files --error-unmatch scripts/ralph/prd.json >/dev/null 2>&1 && fail "epic post-commit prd.json must be untracked"
      git -C "$EPIC_REPO" ls-files --error-unmatch scripts/ralph/progress.txt >/dev/null 2>&1 && fail "epic post-commit progress.txt must be untracked"
      ./ralph-sprint-commit.sh > "$WORK_DIR/sprint-commit-epic.log" 2>&1
    )
    assert_contains "$WORK_DIR/doctor-epic.log" "OK: prerequisites present"
    assert_contains "$WORK_DIR/sprint-create-epic.log" "Created sprint: sprint-1"
    assert_contains "$WORK_DIR/epic-add-epic.log" "Added epic: EPIC-001"
    assert_contains "$WORK_DIR/epic-start-loop.log" "Active epic: EPIC-001"
    assert_prime_log_primed "$WORK_DIR/prime-epic.log"
    assert_contains "$WORK_DIR/loop-epic.log" "Iteration"
    assert_not_contains "$WORK_DIR/loop-epic.log" "node: bad option: --runInBand"
    if [ "$APP_MODE" = "ui" ]; then
      assert_contains "$WORK_DIR/runtime-epic.log" "browser ok: $epic_expected_msg"
    else
      assert_contains "$WORK_DIR/runtime-epic.log" "^$epic_expected_msg$"
    fi
    assert_contains "$WORK_DIR/test-epic.log" "test ok"
    epic_planning_tokens="$(extract_tokens_from_log "$WORK_DIR/prime-epic.log")"
    assert_contains "$WORK_DIR/commit-plan-epic-default.log" "target branch:  $epic_expected_target"
    assert_contains "$WORK_DIR/commit-plan-epic-target.log" "target branch:  $epic_expected_target"
    assert_contains "$WORK_DIR/commit-plan-epic-default.log" "prd mode:       epic"
    assert_contains "$WORK_DIR/commit-plan-epic-default.log" "prd base:       $epic_expected_target"
    assert_contains "$WORK_DIR/commit-epic.log" "Deleted source branch:"
    epic_tokens="$(extract_tokens_from_log "$WORK_DIR/loop-epic.log")"
    epic_tokens=$((epic_tokens + epic_planning_tokens))
    epic_iterations="$(extract_iteration_count_from_log "$WORK_DIR/loop-epic.log")"
    epic_completed_iteration="$(extract_completed_iteration_from_log "$WORK_DIR/loop-epic.log")"
  fi

  total_tokens=$((standalone_tokens + epic_tokens))
  if [ "$standalone_tokens" -eq 0 ] && [ "$epic_tokens" -eq 0 ]; then
    echo "[smoke] token summary: unavailable (no 'tokens used' markers emitted by codex output)"
  else
    echo "[smoke] token summary (planning+loop): app_mode=$APP_MODE mode=$LOOP_MODE standalone=$standalone_tokens epic=$epic_tokens total=$total_tokens"
    echo "[smoke] token detail: standalone_planning=$standalone_planning_tokens standalone_loop=$((standalone_tokens-standalone_planning_tokens)) epic_planning=$epic_planning_tokens epic_loop=$((epic_tokens-epic_planning_tokens))"
    echo "[smoke] loop detail: standalone_iterations=$standalone_iterations standalone_completed_iteration=$standalone_completed_iteration epic_iterations=$epic_iterations epic_completed_iteration=$epic_completed_iteration"
  fi
fi


echo "[smoke] PASS: install-repo E2E sanity checks completed"
