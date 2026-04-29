# Ralph

![Ralph](ralph.webp)

Ralph is a Codex-native autonomous loop that keeps running `codex exec` in fresh context until a planned task is complete. Durable planning artifacts stay in git, while loop runtime state stays transient and gets archived at closeout.

This repo is the current Ralph-for-Codex framework:

- simpler operator flow: install, plan, run, commit
- two real working modes: `standalone` and `sprint`
- roadmap planning for multi-sprint work
- automatic epic priming in sprint mode
- handoff-driven completion and archive validation
- light scope enforcement for explicitly file-scoped tasks
- repo-local prompt extensions that survive framework reinstalls

## What Changed

The framework is simpler than earlier Ralph variants:

- You do not manually stitch together the loop from separate low-level steps.
- `ralph.sh` now handles normal sprint startup by auto-calling `ralph-prime.sh`.
- Completion is wrapper-driven and canonicalized in `scripts/ralph/.completion-state.json`.
- Per-iteration state is captured in structured `.iteration-handoff*.json` files, with transcripts preserved separately.
- PRD markdown is durable and committed; `scripts/ralph/prd.json` and `scripts/ralph/progress.txt` are runtime-only and should remain untracked.
- Sprint planning now has a first-class roadmap tool instead of relying on ad hoc manual backlog setup.

## Current Process

Ralph has two operator-facing workflows.

### 1. Standalone

Use this when the task is a single bounded piece of work.

```bash
bash /path/to/ralph/install.sh
./scripts/ralph/doctor.sh
./scripts/ralph/ralph-prd.sh --feature "Describe the task"
./scripts/ralph/ralph.sh 10
./scripts/ralph/ralph-commit.sh
```

What happens:

- `ralph-prd.sh` generates durable PRD markdown and transient `prd.json`
- `ralph.sh` runs one story at a time with fresh Codex context
- targeted verification runs each iteration
- full verification runs before completion
- `ralph-commit.sh` archives the run, merges to the base branch, and resets runtime state

### 2. Sprint

Use this when the work needs an ordered backlog of epics.

```bash
bash /path/to/ralph/install.sh
./scripts/ralph/doctor.sh
./scripts/ralph/ralph-roadmap.sh --vision "Describe the future-state roadmap"
./scripts/ralph/ralph-sprint.sh status
./scripts/ralph/ralph.sh 10
./scripts/ralph/ralph-commit.sh
```

Then repeat:

```bash
./scripts/ralph/ralph.sh 10
./scripts/ralph/ralph-commit.sh
```

When the sprint backlog is done:

```bash
./scripts/ralph/ralph-sprint-commit.sh
```

What happens:

- `ralph-roadmap.sh` creates or refines sprint backlogs from a broad vision
- `ralph.sh` auto-primes the next eligible epic through `ralph-prime.sh`
- epic PRD markdown can be generated from `promptContext` when needed
- each completed epic is archived and merged into the sprint branch
- sprint closeout merges the sprint branch into `main` or `master`

## Quick Start

### Install into a project

From the target repo root:

```bash
bash /path/to/ralph/install.sh
./scripts/ralph/doctor.sh
```

Optional global installs:

```bash
bash /path/to/ralph/install.sh --install-skills
bash /path/to/ralph/install.sh --install-prompts
```

Prerequisites:

- [Codex CLI](https://github.com/openai/codex) installed and authenticated
- `jq`
- a git repository

## Core Capabilities

### Planning

- `ralph-prd.sh` creates standalone PRDs with an editor-first or CLI-first intake flow
- optional compact planning mode exists for truly tiny, tightly scoped tasks: `--compact` or `RALPH_PRD_COMPACT=1`
- compact mode auto-selection is intentionally conservative
- `ralph-roadmap.sh` creates or refines a durable roadmap in `scripts/ralph/roadmap-source.md`
- roadmap planning decomposes work into sprint-safe epics with effort scores `1`, `2`, `3`, or `5`
- sprint backlogs carry `capacityTarget` and `capacityCeiling`
- roadmap-managed epics and local ad hoc epics are tracked separately so refinement is additive by default

### Execution

- every Ralph iteration is a fresh Codex run with clean context
- `ralph.sh` works story-by-story, not task-batch-by-task-batch
- sprint mode normally needs no manual `ralph-prime.sh` or `start-next`
- completion is based on observable state, not fragile final-message wording
- Ralph writes `.completion-state.json` itself when completion is stable
- loop state is handoff-driven via `.iteration-handoff-iter-*.json` and `.iteration-handoff-latest.json`

### Verification

- `ralph-verify.sh --targeted` runs typecheck, lint, and related tests for changed files
- targeted verification falls back to the full suite when source changed but no related tests can be inferred
- `ralph-verify.sh --full` is the final regression gate
- known unrelated baseline failures can be listed in `scripts/ralph/known-test-baseline-failures.txt`
- UI work can include browser/runtime verification without widening the requested source-edit scope

### Scope Control

- if the PRD clearly says a task is limited to named files, Ralph enforces that scope at loop time
- structured `scopePaths` in `prd.json` take priority over text inference
- verification and test files may expand outside source scope when that expansion is only for verification
- helper scripts, config files, fixtures, and package metadata should not be placed in `scopePaths` unless the task explicitly requires them

### Closeout

- `ralph-commit.sh` validates completion, archives artifacts, merges, and syncs epic status in sprint mode
- `ralph-sprint-commit.sh` closes the sprint and merges the sprint branch
- `ralph-archive.sh` stores runtime evidence under `scripts/ralph/tasks/archive/...`
- merged source branches are deleted by default; pass `--keep` to retain them

### Repo-local Extensions

- keep repo-specific behavior in `scripts/ralph/prompt.local.md`
- `ralph.sh` supports marker-based prompt injection with `<!-- RALPH:LOCAL:<NAME> -->`
- empty local prompt files are ignored
- legacy non-marker local prompt content falls back to append mode
- framework reinstall does not overwrite `prompt.local.md`

See [README-local.md](README-local.md).

## Command Surface

```bash
# Install / validate
./install.sh --project /path/to/project
./doctor.sh

# Standalone planning
./ralph-prd.sh
./ralph-prd.sh --feature "Add saved filters" --constraints "Use existing schema" --no-questions

# Roadmap / sprint planning
./ralph-roadmap.sh --vision "Roadmap from current state to target state"
./ralph-roadmap.sh --refine --revision-note "Adjust after new findings"
./ralph-sprint.sh status
./ralph-sprint.sh next
./ralph-sprint.sh next --activate
./ralph-sprint.sh create sprint-2
./ralph-sprint.sh use sprint-1

# Epic helpers
./ralph-epic.sh list
./ralph-epic.sh next
./ralph-epic.sh start-next
./ralph-epic.sh add --title "My Epic" --effort 3 --prompt-context "Planning context"

# Spec helpers
./ralph-spec-check.sh scripts/ralph/tasks/prds/my-prd.md
./ralph-spec-strengthen.sh scripts/ralph/tasks/prds/my-prd.md

# Loop / verification / closeout
./ralph.sh 10
./ralph-verify.sh --targeted
./ralph-verify.sh --full
./ralph-commit.sh
./ralph-sprint-commit.sh
./ralph-archive.sh
./ralph-cleanup.sh --force
```

## Runtime Model

Durable artifacts:

- PRD markdown under `scripts/ralph/tasks/...`
- roadmap source and sprint backlog files
- git history
- archived run evidence under `scripts/ralph/tasks/archive/...`

Transient runtime artifacts:

- `scripts/ralph/prd.json`
- `scripts/ralph/progress.txt`
- `scripts/ralph/.completion-state.json`
- `scripts/ralph/.active-prd`
- `scripts/ralph/.iteration-log*.txt`
- `scripts/ralph/.iteration-handoff*.json`
- `.playwright-cli/`

Transient runtime files should stay untracked. Ralph will fail or clean up when they drift into git tracking.

## Smoke Testing The Framework

Run the install-repo E2E smoke suite in disposable repos:

```bash
bash scripts/smoke/e2e-sanity.sh --ci
bash scripts/smoke/e2e-sanity.sh --with-loop
bash scripts/smoke/e2e-sanity.sh --with-loop-standalone
bash scripts/smoke/e2e-sanity.sh --with-loop-epic
bash scripts/smoke/e2e-sanity.sh --with-loop --app-mode ui
```

Notes:

- local runs default to real `codex`
- `--ci` uses the mock Codex harness for deterministic checks
- smoke telemetry reports token totals and iteration counts
- benchmark history is stored under `scripts/smoke/.benchmarks/`

## Key Files

| File | Purpose |
|------|---------|
| `install.sh` | Install Ralph into a target repo |
| `doctor.sh` | Sanity-check a Ralph-enabled repo |
| `ralph-prd.sh` | Create standalone PRD markdown and transient `prd.json` |
| `ralph-roadmap.sh` | Create or refine the durable roadmap and seed sprint backlogs |
| `ralph-sprint.sh` | Manage sprint containers and sprint readiness |
| `ralph-epic.sh` | Inspect and adjust epic backlog sequencing |
| `ralph-prime.sh` | Prime `prd.json` from sprint backlog state |
| `ralph-spec-check.sh` | Check whether a PRD markdown file is loop-ready for Ralph |
| `ralph-spec-strengthen.sh` | Strengthen a PRD markdown file in place until it is loop-ready |
| `ralph.sh` | Run the clean-context Codex loop |
| `ralph-verify.sh` | Run targeted or full verification |
| `ralph-commit.sh` | Archive and merge one completed PRD run |
| `ralph-sprint-commit.sh` | Archive and merge the completed sprint |
| `ralph-archive.sh` | Archive current runtime artifacts |
| `ralph-cleanup.sh` | Reset local Ralph runtime artifacts without archiving |
| `prompt.md` | Shared base prompt used every iteration |
| `prompt.standalone.md` | Standalone-mode overlay |
| `prompt.sprint.md` | Sprint-mode overlay |
| `prompt.local.md` | Repo-local prompt extensions |
| `prd.json.example` | Example PRD format |
| `epics.json.example` | Example sprint epic backlog format |

## Notes

- Fresh installs seed `sprint-1`; create more sprints only when needed.
- `ralph-sprint.sh status` reports both `Active epic` and `Next epic`.
- `ralph-sprint.sh next` skips pre-baseline roadmap sprints when their only remaining epics are `blocked`, so stale historic work does not outrank the current roadmap sprint.
- `ralph-archive.sh` has no `--help`; invoking it performs an archive run.
- OpenSpec conversion is optional and does not change core Ralph loop behavior.
- Keep `prompt.md` small because every loop iteration pays for it again.

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [Upstream Ralph (Amp-based)](https://github.com/snarktank/ralph)
- [Codex CLI](https://github.com/openai/codex)
