# Ralph

![Ralph](ralph.webp)

Ralph is an autonomous AI agent loop that runs Codex (`codex --yolo exec`) repeatedly until all PRD items are complete. Each iteration is a fresh Codex run with clean context. Memory persists via git history, `progress.txt`, and `prd.json`.

This repo is a Codex-focused variant of the original Ralph implementation:
- Upstream: https://github.com/snarktank/ralph (Amp-based)
- This repo: replaces Amp with Codex, and adds `install.sh` + `doctor.sh` for reliable setup/smoke checks.

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
./scripts/ralph/ralph-prd.sh
./scripts/ralph/ralph.sh 10
```

Install skills globally (optional):

```bash
bash /path/to/ralph/install.sh --install-skills
```

### Install as Codex skills (recommended)

If you want to use the included skills (`prd`, `ralph`, `setup-ralph-for-codex`) in any project, install them once:

```bash
cd /path/to/ralph
bash ./install.sh --install-skills
```

### Option 1: Copy to your project

Copy the ralph files into your project:

```bash
# From your project root
mkdir -p scripts/ralph
cp /path/to/ralph/ralph.sh scripts/ralph/
cp /path/to/ralph/ralph-prd.sh scripts/ralph/
cp /path/to/ralph/doctor.sh scripts/ralph/
cp /path/to/ralph/prompt.md scripts/ralph/
cp /path/to/ralph/install.sh scripts/ralph/
chmod +x scripts/ralph/ralph.sh
chmod +x scripts/ralph/ralph-prd.sh
chmod +x scripts/ralph/doctor.sh
chmod +x scripts/ralph/install.sh
```

### Option 2: Install skills globally

Copy the skills to your Codex skills directory for use across all projects:

```bash
mkdir -p ~/.codex/skills
cp -r skills/prd ~/.codex/skills/
cp -r skills/ralph ~/.codex/skills/
```

## Workflow

### 1. Generate PRD + prd.json (wrapper)

Use the wrapper to collect your feature concept, generate `tasks/prd-[feature-name].md`, and convert to `scripts/ralph/prd.json` in one flow:

```bash
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

### 2. Run Ralph

```bash
./scripts/ralph/doctor.sh
./scripts/ralph/ralph.sh [max_iterations]
```

Default is 10 iterations.

Ralph will:
1. Create a feature branch (from PRD `branchName`)
2. Pick the highest priority story where `passes: false`
3. Implement that single story
4. Run quality checks (typecheck, tests)
5. Commit if checks pass
6. Update `prd.json` to mark story as `passes: true`
7. Append learnings to `scripts/ralph/progress.txt`
8. Repeat until all stories pass or max iterations reached

## Key Files

| File | Purpose |
|------|---------|
| `ralph-prd.sh` | Interactive wrapper to create PRDs and convert to `prd.json` via Codex skills |
| `ralph.sh` | The bash loop that spawns fresh Codex runs |
| `prompt.md` | Instructions given to each Codex run |
| `prd.json` | User stories with `passes` status (the task list) |
| `prd.json.example` | Example PRD format for reference |
| `progress.txt` | Append-only learnings for future iterations |
| `skills/prd/` | Skill for generating PRDs |
| `skills/ralph/` | Skill for converting PRDs to JSON |
| `flowchart/` | Interactive visualization of how Ralph works |

## Flowchart

[![Ralph Flowchart](ralph-flowchart.png)](https://snarktank.github.io/ralph/)

**[View Interactive Flowchart](https://snarktank.github.io/ralph/)** - Click through to see each step with animations.

The `flowchart/` directory contains the source code. To run locally:

```bash
cd flowchart
npm install
npm run dev
```

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

## Archiving

Ralph automatically archives previous runs when you start a new feature (different `branchName`). Archives are saved to `archive/YYYY-MM-DD-feature-name/`.

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [Upstream Ralph (Amp-based)](https://github.com/snarktank/ralph)
- [Codex CLI](https://github.com/openai/codex)
- [This repo (Codex port)](https://github.com/aytzey/ralph_for_codex)
