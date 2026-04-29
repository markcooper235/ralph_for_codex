# Ralph Agent Instructions

## Overview

Ralph is an autonomous Codex loop that runs fresh `codex exec` sessions until all PRD stories are complete.

Keep this file focused on the broad operating model. Deeper framework notes, edge cases, and maintainer guidance live in [`docs/maintainer-notes.md`](docs/maintainer-notes.md).

## Operator Modes

Ralph has two real operator-facing workflows:

1. `standalone`
2. `sprint`

Roadmap planning is part of sprint mode. It plans ordered sprint backlogs; the runtime flow is still sprint mode.

## Core Commands

```bash
# Install Ralph into a target project
./install.sh --project /path/to/project

# Optional global Codex assets
./install.sh --install-skills
./install.sh --install-prompts

# Validate a Ralph-enabled repo
./doctor.sh

# Standalone planning
./ralph-prd.sh

# Sprint / roadmap planning
./ralph-roadmap.sh --vision "Roadmap from baseline to target state"
./ralph-sprint.sh status
./ralph-sprint.sh next
./ralph-sprint.sh next --activate

# Loop execution
./ralph.sh [max_iterations]

# Closeout
./ralph-commit.sh
./ralph-sprint-commit.sh

# Advanced / recovery helpers
./ralph-epic.sh list
./ralph-prime.sh
./ralph-spec-check.sh scripts/ralph/tasks/prds/my-prd.md
./ralph-spec-strengthen.sh scripts/ralph/tasks/prds/my-prd.md
./ralph-cleanup.sh --force
```

## Recommended Flow

Standalone:

1. Run `./doctor.sh`
2. Create the PRD with `./ralph-prd.sh`
3. Run `./ralph.sh [max_iterations]`
4. Run `./ralph-commit.sh`

Sprint:

1. Run `./doctor.sh`
2. Plan backlog with `./ralph-roadmap.sh --vision "..."`
3. Check readiness with `./ralph-sprint.sh status`
4. Run `./ralph.sh [max_iterations]`
5. Run `./ralph-commit.sh` after each completed epic
6. Repeat until sprint epics are done or abandoned
7. Run `./ralph-sprint-commit.sh`

Normal sprint runs should start with `./ralph.sh`, not manual `ralph-prime.sh`. The loop auto-primes the next eligible epic.

## Key Files

- `ralph-prd.sh` - Create standalone PRDs and transient `prd.json`
- `ralph-roadmap.sh` - Plan or refine roadmap-driven sprint backlogs
- `ralph-sprint.sh` - Manage sprint containers and sprint readiness
- `ralph-epic.sh` - Inspect or adjust epic backlog state
- `ralph-prime.sh` - Advanced helper that primes `prd.json` from the active sprint backlog
- `ralph-spec-check.sh` - Check whether a PRD markdown file is loop-ready for Ralph
- `ralph-spec-strengthen.sh` - Strengthen a PRD markdown file in place until it is loop-ready
- `ralph.sh` - Main clean-context loop
- `ralph-verify.sh` - Targeted and full verification wrapper
- `ralph-commit.sh` - Archive and merge a completed standalone PRD or sprint epic
- `ralph-sprint-commit.sh` - Close and merge the completed sprint
- `ralph-archive.sh` - Archive current runtime artifacts
- `ralph-cleanup.sh` - Reset local Ralph runtime state without archiving
- `prompt.md` - Base loop prompt
- `prompt.local.md` - Repo-local prompt extensions that should survive framework reinstalls

## Broad Rules

- Each iteration is a fresh Codex run with clean context.
- Durable planning artifacts belong in git; runtime loop state does not.
- Keep stories small enough to finish in one context window.
- Prefer the simple operator flow in docs and prompts: install, plan, run, commit.
- Fresh installs already seed `sprint-1`; create more sprints only when needed.
- `ralph-archive.sh` has no `--help`; running it performs an archive.

## Artifact Rules

Durable:

- PRD markdown under `scripts/ralph/tasks/...`
- roadmap and sprint backlog files
- git history
- archived run artifacts under `scripts/ralph/tasks/archive/...`

Transient and should remain untracked:

- `scripts/ralph/prd.json`
- `scripts/ralph/progress.txt`
- `scripts/ralph/.completion-state.json`
- `scripts/ralph/.active-prd`
- `scripts/ralph/.iteration-log*.txt`
- `scripts/ralph/.iteration-handoff*.json`
- `.playwright-cli/`

## Current Framework Behaviors

- `ralph.sh` auto-primes sprint work through `ralph-prime.sh`.
- Completion is handoff-driven and finalized by Ralph itself in `.completion-state.json`.
- `ralph-verify.sh --targeted` runs during iterations; `--full` is the final gate.
- Explicit file-scoped tasks are lightly enforced at loop time; verification-oriented file expansion is allowed when needed.
- `ralph-sprint.sh next` ignores pre-baseline roadmap sprints when their remaining epics are only `blocked`.
- `prompt.local.md` is the right place for repo-specific behavior; marker-based local prompt injection is supported.
- `ralph-commit.sh` and `ralph-sprint-commit.sh` delete merged source branches by default unless `--keep` is passed.
- `.active-prd` records `baseBranch`, and closeout should prefer it over merge-target guessing.

## When To Use Advanced Helpers

- Use `ralph-epic.sh` when you need to inspect backlog order, add ad hoc epics, or mark epics abandoned.
- Use `ralph-prime.sh` for recovery or advanced control, not as the default sprint entrypoint.

## More Detail

For maintainer-level notes on roadmap policy, compact planning, scope enforcement, handoff/completion edge cases, smoke harness behavior, and documentation guidance, see [`docs/maintainer-notes.md`](docs/maintainer-notes.md).
