# Ralph

![Ralph](ralph.webp)

Ralph is an autonomous AI agent loop that runs Codex (`codex --yolo exec`) repeatedly until all PRD items are complete. Each iteration is a fresh Codex run with clean context. Memory persists via git history, `progress.txt`, and `prd.json`.

## Current Repo State (2026-03-05)

- Sprint-aware workflow is enabled by default (`scripts/ralph/sprints/<sprint>/epics.json` + `.active-sprint`).
- The installer now provisions full lifecycle scripts: planning (`ralph-prd.sh`, `ralph-prime.sh`), loop execution (`ralph.sh`), sprint/epic management (`ralph-sprint.sh`, `ralph-epic.sh`), and completion/archive (`ralph-commit.sh`, `ralph-sprint-commit.sh`, `ralph-archive.sh`, `ralph-cleanup.sh`).
- An optional OpenSpec adapter is available at `scripts/openspec/openspec-skill.sh` for converting OpenSpec changes into `scripts/ralph/prd.json`.
- Codex assets in this repo include skills (`skills/prd`, `skills/ralph`, `skills/setup`) and reusable command prompts (`prompts/*.md`), both installable via `install.sh`.
- Archive output now lives under `scripts/ralph/tasks/archive/<active-sprint>/...` for epic runs or `scripts/ralph/tasks/archive/prds/...` for standalone PRDs.

## Project Origin

This repository was based on Ryan Carson's Snarktank Ralph work:
- Upstream: https://github.com/snarktank/ralph

It has since been significantly modified into what it is now. It retains the same basic functionality (with major improvements in this version), but it is not the same project.

This repo is a Codex-focused Ralph variant:
- Replaces Amp with Codex
- Adds `install.sh` + `doctor.sh` for more reliable setup and smoke checks

Based on [Geoffrey Huntley's Ralph pattern](https://ghuntley.com/ralph/).

[Read my in-depth article on how I use Ralph](https://x.com/ryancarson/status/2008548371712135632)

## Prerequisites

- [Codex CLI](https://github.com/openai/codex) installed and authenticated (`codex login`)
- `jq` installed (`brew install jq` on macOS)
- A git repository for your project

## Setup

### Option 0: One-command install (recommended)

From your project root:

```bash
bash /path/to/ralph/install.sh
./scripts/ralph/doctor.sh
./scripts/ralph/ralph-sprint.sh status
./scripts/ralph/ralph-prime.sh
./scripts/ralph/ralph.sh 10
```

Install skills globally (optional):

```bash
bash /path/to/ralph/install.sh --install-skills
```

## Framework Smoke Suite

Run install-repo E2E sanity checks in a disposable project:

```bash
bash scripts/smoke/e2e-sanity.sh
# Optional: include real ralph.sh loop runs + token summary
bash scripts/smoke/e2e-sanity.sh --with-loop
```

Notes:
- Local default uses real `codex`.
- CI mode (`--ci`) uses `scripts/smoke/mock-codex.sh` by default for deterministic checks (no Codex auth required).
- Override with `--real-codex` or `--mock-codex` when needed.
- `--with-loop` runs actual Ralph loop iterations for standalone + sprint epic flows and prints token totals from loop logs.
- Uses throwaway temp directories and auto-cleans on success/failure.

### Install as Codex skills (recommended)

If you want to use the included skills (`prd`, `ralph`, `setup-ralph-for-codex`) in any project, install them once:

```bash
cd /path/to/ralph
bash ./install.sh --install-skills
bash ./install.sh --install-prompts
```

### Option 1: Copy to your project

Copy the ralph files into your project:

```bash
# From your project root
mkdir -p scripts/ralph
cp /path/to/ralph/{doctor.sh,install.sh,prompt.md,prd.json.example,epics.json.example} scripts/ralph/
cp /path/to/ralph/ralph*.sh scripts/ralph/
cp /path/to/ralph/known-test-baseline-failures.txt scripts/ralph/
mkdir -p scripts/ralph/lib scripts/ralph/templates
cp /path/to/ralph/lib/editor-intake.sh scripts/ralph/lib/
cp /path/to/ralph/templates/{epic-intake.md,prd-intake.md} scripts/ralph/templates/
chmod +x scripts/ralph/*.sh
chmod +x scripts/ralph/lib/editor-intake.sh

# Optional OpenSpec adapter (separate from scripts/ralph runtime)
mkdir -p scripts/openspec
cp /path/to/ralph/scripts/openspec/openspec-skill.sh scripts/openspec/
chmod +x scripts/openspec/openspec-skill.sh
```

### Option 2: Install skills globally

Copy the skills to your Codex skills directory for use across all projects:

```bash
mkdir -p ~/.codex/skills
cp -r skills/prd ~/.codex/skills/
cp -r skills/ralph ~/.codex/skills/
cp -r skills/setup ~/.codex/skills/
mkdir -p ~/.codex/prompts
cp prompts/*.md ~/.codex/prompts/
```

## Workflow

### 1. Generate PRD + prd.json (wrapper)

Use the wrapper to collect your feature concept, generate `tasks/prd-[feature-name].md`, and convert to `scripts/ralph/prd.json` in one flow:

```bash
# If local skills changed, refresh global copies first
bash ./install.sh --install-skills

./scripts/ralph/ralph-prd.sh
```

Optional modes:

```bash
# Non-interactive (minimal)
./scripts/ralph/ralph-prd.sh --feature "Add saved filters to search"

# Add hard constraints without extra prompts
./scripts/ralph/ralph-prd.sh --feature "Add saved filters to search" --constraints "Must use existing DB schema"

# Force 3 quick clarifier questions
./scripts/ralph/ralph-prd.sh --quick-questions

# Skip clarifier questions entirely
./scripts/ralph/ralph-prd.sh --no-questions

# Quieter wrapper logs
./scripts/ralph/ralph-prd.sh --quiet
```

The wrapper enforces small, ordered stories and requires completion criteria like typecheck, lint, and tests.

### 2. Prepare Sprint + Epic Context

```bash
./scripts/ralph/doctor.sh
./scripts/ralph/ralph-sprint.sh status
./scripts/ralph/ralph-epic.sh list
./scripts/ralph/ralph-prime.sh
```

`ralph-sprint.sh status` now displays both the current `Active epic` (if any) and the `Next epic` candidate to reduce sequencing ambiguity.

### Alternative Planning Path: OpenSpec -> Ralph

If you use OpenSpec for planning, convert a change into a Ralph-compatible `prd.json`:

```bash
./scripts/openspec/openspec-skill.sh init
./scripts/openspec/openspec-skill.sh list
./scripts/openspec/openspec-skill.sh convert --change <change-name>
```

Notes:
- This is optional and separate from core Ralph runtime.
- It writes the same `scripts/ralph/prd.json` format used by `ralph-prd.sh`/`ralph-prime.sh`.
- `ralph.sh` behavior is unchanged; it still consumes `scripts/ralph/prd.json`.

### 3. Run Ralph

```bash
./scripts/ralph/ralph.sh [max_iterations]
```

Default is 10 iterations.

Ralph will:
1. Create a feature branch (from PRD `branchName`)
2. Pick the highest priority story where `passes: false`
3. Implement that single story
4. Run `./scripts/ralph/ralph-verify.sh --targeted` (typecheck + lint + targeted tests)
5. Commit if checks pass
6. Update `prd.json` to mark story as `passes: true`
7. Append learnings to `scripts/ralph/progress.txt`
8. Before final completion, run `./scripts/ralph/ralph-verify.sh --full` for regression gate
9. Repeat until all stories pass or max iterations reached

### Repo-specific Utilities

Use `scripts/ralph/prompt.local.md` for install-repo-specific instructions (for example, custom auth setup helpers or local utility scripts).  
`ralph.sh` appends this file to the generated loop prompt when present, and framework updates via `install.sh` do not overwrite it.

### Epic-level sequencing

Use epic backlog sequencing to decide what to run next before preparing each loop:

```bash
./scripts/ralph/ralph-epic.sh list
./scripts/ralph/ralph-epic.sh next
./scripts/ralph/ralph-epic.sh start-next
./scripts/ralph/ralph-epic.sh add --title "My Epic" --depends-on EPIC-001 --prompt-context "Planning context"
./scripts/ralph/ralph-epic.sh set-status EPIC-001 done
./scripts/ralph/ralph-epic.sh abandon EPIC-009 "superseded by EPIC-011"
./scripts/ralph/ralph-epic.sh remove EPIC-009
```

Recommended cycle:
1. Ensure active sprint is set (`ralph-sprint.sh use <sprint-name>` or `create`)
2. Select next epic (`start-next`)
3. Prime `scripts/ralph/prd.json` for that epic (`ralph-prime.sh`)
4. Run `ralph.sh`
5. Run `ralph-commit.sh` to archive + merge epic branch into sprint branch; it auto-marks the matching epic `done`
6. When all sprint epics are done/abandoned, run `ralph-sprint-commit.sh` to archive sprint closeout and merge sprint branch into `master`/`main`

Notes:
- `abandon` keeps an epic in backlog history but excludes it from eligibility.
- `remove` permanently deletes only epics already marked `abandoned`.
- Fresh installs seed `sprint-1`; use `create` for additional sprints.
- Use `ralph-epic.sh add ...` for non-interactive epic creation in automation scripts.
- `ralph-commit.sh` deletes the merged source feature branch by default; use `--keep` to retain it.
- `ralph-sprint-commit.sh` deletes the merged sprint branch by default; use `--keep` to retain it.
- `ralph-prime.sh --auto` now auto-commits primed epic status changes by default.
- `ralph-prime.sh` falls back to the currently active epic when no next eligible epic exists.
- `ralph-sprint.sh create` / `add-epic` use editor intake and generate the primary PRD task file before writing the new epic entry to `epics.json`.
- `ralph-sprint.sh remove <sprint> [--hard --yes --drop-branch]` archives/removes sprint state; `--hard` implies branch deletion.
- `ralph.sh` no longer performs run archiving in-loop; archive/merge stays in `ralph-commit.sh` (or `ralph-archive.sh` manually).
- On PRD branch switch, `ralph.sh` requires the previous branch to already be archived and exits with guidance if not.
- `ralph.sh --auto-finalize-epic` only commits `epics.json` and skips if other tracked files are dirty.
- During active iterations, `scripts/ralph/.codex-last-message-iter-N.txt` is initialized with a small `status=running` marker for observability.
- `scripts/ralph/prd.json` and `scripts/ralph/progress.txt` are runtime-only files and must remain untracked; `ralph.sh` aborts if they become tracked mid-run.

## Key Files

| File | Purpose |
|------|---------|
| `ralph-prd.sh` | Interactive wrapper to create PRDs and convert to `prd.json` via Codex skills |
| `ralph-prime.sh` | Prime `prd.json` from next eligible epic, or fall back to active epic when needed; auto-commits primed epic state in `--auto` mode |
| `ralph-verify.sh` | Standardized verification wrapper (`--targeted` per iteration, `--full` before completion) |
| `ralph.sh` | The bash loop that spawns fresh Codex runs |
| `scripts/openspec/openspec-skill.sh` | Optional OpenSpec adapter for converting OpenSpec changes into `prd.json` |
| `ralph-sprint.sh` | Manage sprint containers (`create`, `use`, `status`, `add-epic(s)`, `remove`); status reports both active and next epic |
| `ralph-epic.sh` | CLI to list/select/activate epic order and add epics non-interactively within active sprint |
| `ralph-archive.sh` | Archive run artifacts and reset `prd.json` |
| `ralph-commit.sh` | Validate, archive, merge epic branch into sprint branch, and sync epic `done` status |
| `ralph-sprint-commit.sh` | Validate sprint completion, archive sprint closeout, and merge sprint branch into `master`/`main` |
| `ralph-cleanup.sh` | Reset local Ralph artifacts (including active markers) without creating archive |
| `prompt.md` | Instructions given to each Codex run |
| `prompt.local.md` | Optional repo-local prompt extension automatically appended by `ralph.sh`; use for one-off utilities/policies that must survive framework updates |
| `known-test-baseline-failures.txt` | Known unrelated full-suite baseline failures to ignore during final regression gate |
| `prd.json` | User stories with `passes` status (the task list) |
| `prd.json.example` | Example PRD format for reference |
| `sprints/<sprint>/epics.json` | Sprint-scoped epic backlog with priority/dependencies/activeEpicId |
| `epics.json.example` | Example epic backlog template |
| `lib/editor-intake.sh` | Shared editor launcher/parsing helpers used by sprint/PRD intake flows |
| `templates/epic-intake.md` | Editor template for epic metadata and prompt context capture |
| `templates/prd-intake.md` | Editor template for standalone PRD concept capture |
| `progress.txt` | Append-only learnings for future iterations |
| `prompts/*.md` | Optional slash-command style prompt templates installable to `~/.codex/prompts` |
| `skills/prd/` | Skill for generating PRDs |
| `skills/ralph/` | Skill for converting PRDs to JSON |
| `skills/setup/` | Skill for installing/configuring Ralph in target projects |

Flowchart assets/source were removed because they are no longer valid for this repository. A new repo-specific flowchart may be added in the future.

## Critical Concepts

### Each Iteration = Fresh Context

Each iteration spawns a **new Codex run** with clean context. The only memory between iterations is:
- Git history (commits from previous iterations)
- `progress.txt` (learnings and context)
- `prd.json` (which stories are done)

### Small Tasks

Each PRD item should be small enough to complete in one context window. If a task is too big, the LLM runs out of context before finishing and produces poor code.

Right-sized stories:
- Add a database column and migration
- Add a UI component to an existing page
- Update a server action with new logic
- Add a filter dropdown to a list

Too big (split these):
- "Build the entire dashboard"
- "Add authentication"
- "Refactor the API"

### AGENTS.md Updates Are Critical

After each iteration, Ralph updates the relevant `AGENTS.md` files with learnings. This is key because the next Codex run (and future human developers) can quickly pick up important patterns, gotchas, and conventions.

Examples of what to add to AGENTS.md:
- Patterns discovered ("this codebase uses X for Y")
- Gotchas ("do not forget to update Z when changing W")
- Useful context ("the settings panel is in component X")

### Feedback Loops

Ralph only works if there are feedback loops:
- Typecheck catches type errors
- Tests verify behavior
- CI must stay green (broken code compounds across iterations)

### Browser Verification for UI Stories

Frontend stories must include a verifiable UI check in acceptance criteria. Prefer automated checks (Playwright/Cypress/etc.) if available; if you have a browser automation skill (e.g., `dev-browser`), use it to verify the UI end-to-end.

### Stop Condition

When all stories have `passes: true`, Ralph outputs `<promise>COMPLETE</promise>` and the loop exits.

## Debugging

Check current state:

```bash
# See which stories are done
cat scripts/ralph/prd.json | jq '.userStories[] | {id, title, passes}'

# See learnings from previous iterations
cat scripts/ralph/progress.txt

# Check git history
git log --oneline -10
```

## Customizing prompt.md

Edit `prompt.md` to customize Ralph's behavior for your project:
- Add project-specific quality check commands
- Include codebase conventions
- Add common gotchas for your stack

Optional supporting files:
- `known-test-baseline-failures.txt` to control known-unrelated full-suite failures for `ralph-verify.sh --full`

## Archiving

Epic archive/merge flow is handled by `./scripts/ralph/ralph-commit.sh`, which calls `ralph-archive.sh` first.
`./scripts/ralph/ralph.sh` does not archive runs; it expects archive/merge to happen outside the loop.

Sprint closeout/merge is handled by `./scripts/ralph/ralph-sprint-commit.sh`.

Archive destinations:
- Epic-mode run: `scripts/ralph/tasks/archive/<active-sprint>/YYYY-MM-DD-feature-name/`
- Standalone PRD run: `scripts/ralph/tasks/archive/prds/YYYY-MM-DD-feature-name/`

Note: `ralph-archive.sh` does not implement `--help`; running it executes an archive operation.

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [Upstream Ralph (Amp-based)](https://github.com/snarktank/ralph)
- [Codex CLI](https://github.com/openai/codex)
- [This repo (Codex port)](https://github.com/aytzey/ralph_for_codex)
