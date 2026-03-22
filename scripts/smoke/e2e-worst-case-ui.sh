#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=./assert.sh
source "$SCRIPT_DIR/assert.sh"

KEEP_REPO=0
WORK_DIR="$(mktemp -d /tmp/ralph-worst-ui-XXXXXX)"
TMP_HOME="$WORK_DIR/home"
TEST_REPO="$WORK_DIR/project"
BENCH_DIR="$REPO_ROOT/scripts/smoke/.benchmarks"
BENCH_FILE="$BENCH_DIR/worst-case-ui.tsv"
LOOP_RETRY_MAX="${LOOP_RETRY_MAX:-2}"
MAX_ITERATIONS="${MAX_ITERATIONS:-8}"
CODEX_BIN_VALUE="codex"

cleanup() {
  local exit_code=$?
  if [ "$KEEP_REPO" -eq 1 ] || [ "$exit_code" -ne 0 ]; then
    echo "[worst-ui] retained temp repo: $TEST_REPO"
    return
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)
      KEEP_REPO=1
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/smoke/e2e-worst-case-ui.sh [--keep]

Runs a heavier real-Codex UI epic smoke scenario with:
- multi-file implementation scope
- multi-story epic planning
- browser verification requirements
- token and iteration reporting
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$TMP_HOME" "$TEST_REPO"

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
  awk '/Ralph Iteration [0-9]+ of [0-9]+/ { count += 1 } END { print count + 0 }' "$log_file"
}

extract_completed_iteration_from_log() {
  local log_file="$1"
  [ -f "$log_file" ] || {
    echo 0
    return 0
  }
  awk 'match($0, /Completed at iteration ([0-9]+) of [0-9]+/, m) { completed = m[1] } END { print completed + 0 }' "$log_file"
}

append_benchmark_row() {
  local status="$1"
  mkdir -p "$BENCH_DIR"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -Iseconds)" \
    "$status" \
    "$planning_tokens" \
    "$loop_tokens" \
    "$iteration_count" \
    "$completed_iteration" \
    >>"$BENCH_FILE"
}

commit_framework_baseline() {
  local repo_root="$1"
  local commit_msg="$2"

  (
    cd "$repo_root"
    git add -A
    git reset -- scripts/ralph/prd.json scripts/ralph/progress.txt >/dev/null 2>&1 || true
    if ! git diff --cached --quiet; then
      git commit -m "$commit_msg" >/dev/null
    fi
  )
}

run_with_retries_logged() {
  local retries="$1"
  local log_file="$2"
  local repo_root="$3"
  shift 3
  local attempt
  : > "$log_file"
  for attempt in $(seq 0 "$retries"); do
    echo "[worst-ui] attempt $((attempt + 1))/$((retries + 1))" >>"$log_file"
    echo "[worst-ui] cmd: $*" >>"$log_file"
    if "$@" >>"$log_file" 2>&1; then
      return 0
    fi
    if [ "$attempt" -ge "$retries" ]; then
      echo "[worst-ui] command failed after $((attempt + 1)) attempt(s)" >>"$log_file"
      return 1
    fi
    clear_stale_workflow_lock_if_safe "$repo_root" "$log_file"
    echo "[worst-ui] retrying..." >>"$log_file"
  done
}

clear_stale_workflow_lock_if_safe() {
  local repo_root="$1"
  local log_file="$2"
  local lock_dir="$repo_root/scripts/ralph/.workflow-lock"

  [ -d "$lock_dir" ] || return 0

  if ps -eo args= | grep -F -- "$repo_root" | grep -v grep >/dev/null 2>&1; then
    echo "[worst-ui] workflow lock still has active repo-scoped processes; leaving lock in place" >>"$log_file"
    return 0
  fi

  rm -rf "$lock_dir"
  echo "[worst-ui] removed stale workflow lock: $lock_dir" >>"$log_file"
}

assert_only_allowed_files_changed() {
  local repo="$1"
  local start_ref="$2"
  local end_ref="$3"
  shift 3
  local allowed_file
  local changed
  local unexpected=()

  changed="$(git -C "$repo" diff --name-only "$start_ref" "$end_ref")"
  while IFS= read -r changed_file; do
    [ -n "$changed_file" ] || continue
    local allowed=0
    for allowed_file in "$@"; do
      if [ "$changed_file" = "$allowed_file" ]; then
        allowed=1
        break
      fi
    done
    if [ "$allowed" -ne 1 ]; then
      unexpected+=("$changed_file")
    fi
  done <<<"$changed"

  if [ "${#unexpected[@]}" -gt 0 ]; then
    fail "worst-case loop changed files outside strict allowlist:
$(printf '%s\n' "${unexpected[@]}")"
  fi
}

echo "[worst-ui] work dir: $WORK_DIR"
echo "[worst-ui] codex: $CODEX_BIN_VALUE"

cd "$TEST_REPO"
git init -b main >/dev/null
git config user.name "Ralph Worst Smoke"
git config user.email "ralph-worst@example.com"

cat > package.json <<'JSON'
{
  "name": "ralph-worst-ui",
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
    "playwright": "^1.55.0",
    "typescript": "^5.9.2"
  }
}
JSON

cat > tsconfig.json <<'JSON'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "rootDir": "src",
    "outDir": "dist",
    "skipLibCheck": true
  },
  "include": ["src/**/*.ts"]
}
JSON

mkdir -p src scripts tests

cat > src/messages.ts <<'TS'
export const uiCopy = {
  headline: "Hello World",
  status: "Draft mode",
  cta: "Open details",
  state: "draft",
};
TS

cat > src/render.ts <<'TS'
import { uiCopy } from "./messages.js";

export function render() {
  const headline = document.getElementById("app");
  const status = document.getElementById("status");
  const cta = document.getElementById("cta");

  if (headline) headline.textContent = uiCopy.headline;
  if (status) status.textContent = uiCopy.status;
  if (cta) cta.textContent = uiCopy.cta;
}
TS

cat > src/index.ts <<'TS'
import { render } from "./render.js";

render();
TS

cat > index.html <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Ralph Worst Case UI</title>
</head>
<body>
  <main>
    <h1 id="app"></h1>
    <p id="status"></p>
    <button id="cta" type="button"></button>
  </main>
  <script type="module" src="./dist/index.js"></script>
</body>
</html>
HTML

cat > scripts/run-tests.mjs <<'JS'
import { readdirSync, statSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

function collectTests(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...collectTests(full));
    } else if (/(\.test|\.spec)\.m?js$/.test(entry.name)) {
      out.push(full);
    }
  }
  return out;
}

const tests = statSync("tests").isDirectory() ? collectTests("tests") : [];
if (tests.length === 0) throw new Error("No tests found");
for (const testPath of tests) {
  await import(pathToFileURL(path.resolve(testPath)).href);
}
console.log(`PASS ${tests.length} test file(s)`);
console.log("test ok");
JS

cat > scripts/browser-check.mjs <<'JS'
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { chromium } from "playwright";

const expectedHeadline = process.argv[2] || "Hello World";
const expectedStatus = process.argv[3] || "Draft mode";
const expectedCta = process.argv[4] || "Open details";
const expectedState = process.argv[5] || "draft";

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
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
await page.goto(`http://127.0.0.1:${address.port}/index.html`);
await page.waitForFunction(() => {
  const app = document.querySelector("#app");
  const status = document.querySelector("#status");
  const cta = document.querySelector("#cta");
  return [app, status, cta].every((el) => !!el && (el.textContent || "").trim().length > 0);
});
assert.equal((await page.textContent("#app"))?.trim(), expectedHeadline);
assert.equal((await page.textContent("#status"))?.trim(), expectedStatus);
assert.equal((await page.textContent("#cta"))?.trim(), expectedCta);
assert.equal(await page.getAttribute("#status", "data-state"), expectedState);
assert.equal(await page.getAttribute("#cta", "title"), expectedCta);
await browser.close();
server.close();
console.log(`browser ok: ${expectedHeadline} | ${expectedStatus} | ${expectedCta} | ${expectedState}`);
JS

cat > tests/messages.test.mjs <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync("src/messages.ts", "utf8");
assert.match(source, /Hello World/, "Expected baseline headline in src/messages.ts");
assert.match(source, /Draft mode/, "Expected baseline status in src/messages.ts");
assert.match(source, /Open details/, "Expected baseline CTA in src/messages.ts");
assert.match(source, /draft/, "Expected baseline state in src/messages.ts");
JS

cat > tests/render.test.mjs <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync("src/render.ts", "utf8");
assert.match(source, /getElementById\("app"\)/, "Expected render.ts to target #app");
assert.match(source, /getElementById\("status"\)/, "Expected render.ts to target #status");
assert.match(source, /getElementById\("cta"\)/, "Expected render.ts to target #cta");
JS

cat > .gitignore <<'EOF'
dist/
EOF

npm install --silent
npm run build --silent
git add .
git reset dist >/dev/null 2>&1 || true
git commit -m "chore: init worst-case smoke ui" >/dev/null

echo "[worst-ui] refresh skills"
HOME="$TMP_HOME" "$REPO_ROOT/install.sh" --install-skills > "$WORK_DIR/install-skills.log" 2>&1
assert_contains "$WORK_DIR/install-skills.log" "Installed Codex skill: prd"

echo "[worst-ui] install framework"
HOME="$TMP_HOME" "$REPO_ROOT/install.sh" --project "$TEST_REPO" --no-example-prd > "$WORK_DIR/install-framework.log" 2>&1
assert_file_exists "$TEST_REPO/scripts/ralph/doctor.sh"
assert_file_exists "$TEST_REPO/scripts/ralph/ralph-epic.sh"
commit_framework_baseline "$TEST_REPO" "chore: install ralph framework baseline"

EPIC_REPO="$WORK_DIR/project-loop-epic"
cp -a "$TEST_REPO" "$EPIC_REPO"
echo "[worst-ui] isolated repo: epic=$EPIC_REPO"

expected_headline="Hello Sprint Ralph"
expected_status="Ready for review"
expected_cta="View release notes"
expected_state="ready"

(
  cd "$EPIC_REPO/scripts/ralph"
  CODEX_BIN="$CODEX_BIN_VALUE" ./doctor.sh > "$WORK_DIR/doctor-epic.log" 2>&1
  ./ralph-sprint.sh remove sprint-1 --yes --hard > "$WORK_DIR/sprint-reset-epic.log" 2>&1 || true
  RALPH_EDITOR=true ./ralph-sprint.sh create sprint-1 > "$WORK_DIR/sprint-create-epic.log" 2>&1 </dev/null
  ./ralph-epic.sh add \
    --title "Worst Case UI Multi-Story Epic" \
    --status planned \
    --prompt-context "Implement a bounded worst-case UI change. Update src/messages.ts so the headline is Hello Sprint Ralph, the status text is Ready for review, the CTA label is View release notes, and the state is ready. Update src/render.ts so #status renders the status text while exposing the state value, and #cta gets a matching title. Update tests/messages.test.mjs and tests/render.test.mjs for the new copy and render contract. Verify #app, #status, and #cta in the browser, including status text, status state, and CTA title. Keep source changes limited to src/messages.ts, src/render.ts, tests/messages.test.mjs, and tests/render.test.mjs. Verification of that scoped work is allowed only to verify that scoped work. Do not edit browser helpers, build scripts, configs, fixtures, or package.json. Use at least 3 small dependency-ordered stories if verification naturally warrants it." \
    > "$WORK_DIR/epic-add-epic.log" 2>&1
  ./ralph-sprint.sh use sprint-1 > "$WORK_DIR/sprint-use-loop.log" 2>&1
  ./ralph-epic.sh start-next > "$WORK_DIR/epic-start-loop.log" 2>&1
  : > prd.json
  run_with_retries_logged "$LOOP_RETRY_MAX" "$WORK_DIR/prime-epic.log" "$EPIC_REPO" timeout 300 env CODEX_BIN="$CODEX_BIN_VALUE" ./ralph-prime.sh --auto
  jq -e '(.userStories | length) >= 3' prd.json >/dev/null || fail "worst-case epic should plan at least 3 stories"
  ./ralph-sprint.sh status > "$WORK_DIR/status-epic-preloop.log" 2>&1 || true
  epic_loop_start_head="$(git -C "$EPIC_REPO" rev-parse HEAD)"
  run_with_retries_logged "$LOOP_RETRY_MAX" "$WORK_DIR/loop-epic.log" "$EPIC_REPO" timeout 600 env CODEX_BIN="$CODEX_BIN_VALUE" ./ralph.sh "$MAX_ITERATIONS"
  epic_loop_end_head="$(git -C "$EPIC_REPO" rev-parse HEAD)"
  jq -e 'all(.userStories[]; .passes == true)' prd.json >/dev/null
  assert_only_allowed_files_changed "$EPIC_REPO" "$epic_loop_start_head" "$epic_loop_end_head" \
    "src/messages.ts" "src/render.ts" "tests/messages.test.mjs" "tests/render.test.mjs" "tests/browser.test.mjs"
  grep -qF "$expected_headline" "$EPIC_REPO/src/messages.ts" || fail "messages.ts missing expected headline"
  grep -qF "$expected_status" "$EPIC_REPO/src/messages.ts" || fail "messages.ts missing expected status"
  grep -qF "$expected_cta" "$EPIC_REPO/src/messages.ts" || fail "messages.ts missing expected cta"
  grep -qF "$expected_state" "$EPIC_REPO/src/messages.ts" || fail "messages.ts missing expected state"
  grep -qF 'data-state' "$EPIC_REPO/src/render.ts" || fail "render.ts missing status data-state handling"
  grep -qF 'title' "$EPIC_REPO/src/render.ts" || fail "render.ts missing CTA title handling"
  (
    cd "$EPIC_REPO"
    npm run -s build > "$WORK_DIR/build-epic.log" 2>&1
    npm test > "$WORK_DIR/test-epic.log" 2>&1
    npm run -s browser:check -- "$expected_headline" "$expected_status" "$expected_cta" "$expected_state" > "$WORK_DIR/runtime-epic.log" 2>&1
    if git ls-files --error-unmatch dist/index.js >/dev/null 2>&1; then
      git checkout -- dist/index.js
    fi
  )
)

assert_contains "$WORK_DIR/doctor-epic.log" "OK: prerequisites present"
assert_contains "$WORK_DIR/sprint-create-epic.log" "Created sprint: sprint-1"
assert_contains "$WORK_DIR/epic-add-epic.log" "Added epic: EPIC-001"
assert_contains "$WORK_DIR/epic-start-loop.log" "Active epic: EPIC-001"
assert_contains "$WORK_DIR/loop-epic.log" "Iteration"
assert_contains "$WORK_DIR/test-epic.log" "test ok"
assert_contains "$WORK_DIR/runtime-epic.log" "browser ok: $expected_headline \| $expected_status \| $expected_cta \| $expected_state"

planning_tokens="$(extract_tokens_from_log "$WORK_DIR/prime-epic.log")"
loop_tokens="$(extract_tokens_from_log "$WORK_DIR/loop-epic.log")"
iteration_count="$(extract_iteration_count_from_log "$WORK_DIR/loop-epic.log")"
completed_iteration="$(extract_completed_iteration_from_log "$WORK_DIR/loop-epic.log")"
total_tokens=$((planning_tokens + loop_tokens))

echo "[worst-ui] token summary: planning=$planning_tokens loop=$loop_tokens total=$total_tokens"
echo "[worst-ui] iteration summary: iterations=$iteration_count completed_iteration=$completed_iteration"
append_benchmark_row "pass"
echo "[worst-ui] PASS: worst-case UI smoke completed"
