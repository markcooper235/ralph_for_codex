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
    -h|--help)
      cat <<'USAGE'
Usage: scripts/smoke/e2e-sanity.sh [--ci] [--keep] [--real-codex] [--mock-codex] [--with-loop]

Runs disposable install-repo E2E sanity checks.

Options:
  --ci          CI-friendly mode (uses mock codex by default)
  --keep        Keep temp repo for debugging
  --real-codex  Force real codex binary
  --mock-codex  Force mock codex binary
  --with-loop   Run actual ralph.sh loops (standalone + sprint epic)
USAGE
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

WORK_DIR="$(mktemp -d /tmp/ralph-smoke-XXXXXX)"
TMP_HOME="$WORK_DIR/home"
TEST_REPO="$WORK_DIR/project"
mkdir -p "$TMP_HOME" "$TEST_REPO"

cleanup() {
  if [ "$KEEP_REPO" -eq 1 ]; then
    echo "Smoke temp repo retained: $TEST_REPO"
  else
    find "$WORK_DIR" -mindepth 1 -maxdepth 5 -type f >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
  fi
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

cd "$TEST_REPO"
git init -b main >/dev/null

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
    "test": "node -e \"console.log('test ok')\""
  },
  "devDependencies": {
    "typescript": "^5.9.2"
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
console.log("Hello World");
TS

npm install --silent
npm run build --silent

git add .
git commit -m "chore: init smoke hello world" >/dev/null

echo "[smoke] refresh skills"
HOME="$TMP_HOME" "$REPO_ROOT/install.sh" --install-skills > "$WORK_DIR/install-skills.log" 2>&1
assert_contains "$WORK_DIR/install-skills.log" "Installed Codex skill: prd"
assert_file_exists "$TMP_HOME/.codex/skills/prd/SKILL.md"
assert_file_exists "$TMP_HOME/.codex/skills/ralph/SKILL.md"
assert_file_exists "$TMP_HOME/.codex/skills/setup/SKILL.md"


echo "[smoke] install framework"
HOME="$TMP_HOME" "$REPO_ROOT/install.sh" --project "$TEST_REPO" > "$WORK_DIR/install-framework.log" 2>&1
assert_file_exists "$TEST_REPO/scripts/ralph/doctor.sh"
assert_file_exists "$TEST_REPO/scripts/ralph/ralph-epic.sh"
assert_file_exists "$TEST_REPO/scripts/ralph/ralph-prd.sh"


echo "[smoke] doctor"
(
  cd "$TEST_REPO/scripts/ralph"
  CODEX_BIN="$CODEX_BIN_VALUE" ./doctor.sh > "$WORK_DIR/doctor.log" 2>&1
)
assert_contains "$WORK_DIR/doctor.log" "OK: prerequisites present"


echo "[smoke] ralph-prd wrapper"
(
  cd "$TEST_REPO/scripts/ralph"
  CODEX_BIN="$CODEX_BIN_VALUE" ./ralph-prd.sh \
    --feature "Change hello message to Hello PRD Ralph" \
    --constraints "Keep implementation to src/index.ts only" \
    --no-questions > "$WORK_DIR/ralph-prd.log" 2>&1
)
assert_not_contains "$WORK_DIR/ralph-prd.log" "No PRD markdown file"
assert_dir_exists "$TEST_REPO/scripts/ralph/tasks/prds"
prd_count="$(find "$TEST_REPO/scripts/ralph/tasks/prds" -maxdepth 1 -type f -name 'prd-*.md' | wc -l | tr -d ' ')"
[ "$prd_count" -ge 1 ] || fail "Expected at least one PRD markdown in scripts/ralph/tasks/prds"
assert_file_exists "$TEST_REPO/scripts/ralph/prd.json"
assert_json_expr "$TEST_REPO/scripts/ralph/prd.json" '.project and .branchName and (.userStories | length >= 1)'
assert_json_expr "$TEST_REPO/scripts/ralph/prd.json" 'all(.userStories[]; any(.acceptanceCriteria[]; test("(?i)typecheck passes")))'
assert_json_expr "$TEST_REPO/scripts/ralph/prd.json" 'all(.userStories[]; any(.acceptanceCriteria[]; test("(?i)lint passes")))'
assert_json_expr "$TEST_REPO/scripts/ralph/prd.json" 'all(.userStories[]; any(.acceptanceCriteria[]; test("(?i)(unit tests pass|tests pass)")))'


echo "[smoke] recreate sprint-1 + add epic non-interactive"
(
  cd "$TEST_REPO/scripts/ralph"
  ./ralph-sprint.sh remove sprint-1 --yes --hard > "$WORK_DIR/sprint-reset.log" 2>&1 || true
  RALPH_EDITOR=true ./ralph-sprint.sh create sprint-1 > "$WORK_DIR/sprint-create.log" 2>&1
  ./ralph-epic.sh add \
    --title "Change Hello Message: Hello Sprint Ralph" \
    --status planned \
    --prompt-context "Change output greeting to Hello Sprint Ralph in src/index.ts" \
    > "$WORK_DIR/epic-add.log" 2>&1
)
assert_contains "$WORK_DIR/sprint-create.log" "Created sprint: sprint-1"
assert_contains "$WORK_DIR/epic-add.log" "Added epic: EPIC-001"


echo "[smoke] epic commands"
(
  cd "$TEST_REPO/scripts/ralph"
  ./ralph-epic.sh list > "$WORK_DIR/epic-list.log" 2>&1
  ./ralph-epic.sh next > "$WORK_DIR/epic-next.log" 2>&1
  ./ralph-epic.sh next-id > "$WORK_DIR/epic-next-id.log" 2>&1
  ./ralph-epic.sh start-next > "$WORK_DIR/epic-start.log" 2>&1
  ./ralph-epic.sh show EPIC-001 > "$WORK_DIR/epic-show.log" 2>&1
  ./ralph-epic.sh normalize-statuses > "$WORK_DIR/epic-normalize.log" 2>&1
)
assert_contains "$WORK_DIR/epic-list.log" "EPIC-001"
assert_contains "$WORK_DIR/epic-next.log" "Next epic: EPIC-001"
assert_contains "$WORK_DIR/epic-next-id.log" "EPIC-001"
assert_contains "$WORK_DIR/epic-start.log" "Active epic: EPIC-001"


echo "[smoke] sprint commands"
(
  cd "$TEST_REPO/scripts/ralph"
  ./ralph-sprint.sh list > "$WORK_DIR/sprint-list.log" 2>&1
  ./ralph-sprint.sh use sprint-1 > "$WORK_DIR/sprint-use.log" 2>&1
  ./ralph-sprint.sh branch sprint-1 > "$WORK_DIR/sprint-branch.log" 2>&1
  ./ralph-sprint.sh status > "$WORK_DIR/sprint-status.log" 2>&1
  ./ralph-prime.sh --auto > "$WORK_DIR/sprint-prime.log" 2>&1 || true
  ./ralph-commit.sh --dry-run > "$WORK_DIR/sprint-commit-dry.log" 2>&1 || true
  ./ralph-sprint-commit.sh --dry-run > "$WORK_DIR/sprint-sprint-commit-dry.log" 2>&1 || true
  RALPH_EDITOR=true ./ralph-sprint.sh create sprint-2 > "$WORK_DIR/sprint-create-2.log" 2>&1
  ./ralph-sprint.sh remove sprint-2 --yes --hard > "$WORK_DIR/sprint-remove-2.log" 2>&1
)
assert_contains "$WORK_DIR/sprint-list.log" "sprint-1"
assert_contains "$WORK_DIR/sprint-use.log" "Active sprint set to: sprint-1"
assert_contains "$WORK_DIR/sprint-status.log" "Sprint is ready for ralph-prime"
assert_contains "$WORK_DIR/sprint-commit-dry.log" "Not all stories are marked passes=true"
if ! grep -qE "Ralph sprint commit plan|incomplete epics|All sprint epics must be done or abandoned" "$WORK_DIR/sprint-sprint-commit-dry.log"; then
  fail "Unexpected ralph-sprint-commit --dry-run output. See $WORK_DIR/sprint-sprint-commit-dry.log"
fi
assert_contains "$WORK_DIR/sprint-create-2.log" "Created sprint: sprint-2"
assert_contains "$WORK_DIR/sprint-remove-2.log" "Removed sprint directories permanently: sprint-2"

if [ "$WITH_LOOP" -eq 1 ]; then
  echo "[smoke] loop checks (standalone + sprint epic)"
  if [ "$CODEX_BIN_VALUE" != "codex" ]; then
    echo "[smoke] --with-loop requested with non-real codex; forcing real codex for loop phase"
  fi
  LOOP_CODEX_BIN="codex"

  (
    cd "$TEST_REPO/scripts/ralph"
    timeout 420 env CODEX_BIN="$LOOP_CODEX_BIN" ./ralph.sh 3 > "$WORK_DIR/loop-standalone.log" 2>&1 || true
    jq -e 'all(.userStories[]; .passes == true)' prd.json >/dev/null

    # Ralph updates progress.txt during loop runs; reset tracked artifacts before branch switches.
    git restore --worktree --staged scripts/ralph/progress.txt >/dev/null 2>&1 || true

    ./ralph-sprint.sh use sprint-1 > "$WORK_DIR/sprint-use-loop.log" 2>&1
    timeout 300 env CODEX_BIN="$LOOP_CODEX_BIN" ./ralph-prime.sh --auto > "$WORK_DIR/prime-epic.log" 2>&1
    timeout 420 env CODEX_BIN="$LOOP_CODEX_BIN" ./ralph.sh 3 --allow-epic-fallback > "$WORK_DIR/loop-epic.log" 2>&1 || true
    jq -e '.branchName | test("^ralph/.+/epic-[0-9]+$") or test("^ralph/epic-[0-9]+$")' prd.json >/dev/null
    jq -e '([.userStories[] | select(.passes == true)] | length) >= 1' prd.json >/dev/null
  )

  assert_contains "$WORK_DIR/loop-standalone.log" "Iteration"
  assert_contains "$WORK_DIR/prime-epic.log" "Primed scripts/ralph/prd.json"
  assert_contains "$WORK_DIR/loop-epic.log" "Iteration"

  standalone_tokens="$(extract_tokens_from_log "$WORK_DIR/loop-standalone.log")"
  epic_tokens="$(extract_tokens_from_log "$WORK_DIR/loop-epic.log")"
  total_tokens=$((standalone_tokens + epic_tokens))
  if [ "$total_tokens" -eq 0 ]; then
    echo "[smoke] token summary: unavailable (no 'tokens used' markers emitted by codex output)"
  else
    echo "[smoke] token summary: standalone=$standalone_tokens epic=$epic_tokens total=$total_tokens"
  fi
fi


echo "[smoke] PASS: install-repo E2E sanity checks completed"
