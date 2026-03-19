# Ralph Agent Instructions

## Overview

Ralph is an autonomous AI agent loop that runs Codex (`codex --yolo exec`) repeatedly until all PRD items are complete. Each iteration is a fresh Codex run with clean context.

## Commands

```bash
# Install skills globally for Codex
./install.sh --install-skills

# Install Ralph into a target project
./install.sh --project /path/to/your/project

# Generate and convert PRD into scripts/ralph/prd.json
./ralph-prd.sh

# Optional OpenSpec -> Ralph conversion path (outside scripts/ralph runtime)
./scripts/openspec/openspec-skill.sh convert --change <change-name>

# Sprint helpers
./ralph-sprint.sh status
./ralph-sprint.sh create sprint-2
./ralph-sprint.sh use sprint-1

# Epic backlog sequencing helpers
./ralph-epic.sh list
./ralph-epic.sh start-next
./ralph-epic.sh add --title "My Epic" --depends-on EPIC-001 --prompt-context "Epic planning context"

# Prime prd.json for active/next eligible epic
./ralph-prime.sh

# Run Ralph loop (from your project that has prd.json)
./ralph.sh [max_iterations]

# Framework sanity smoke test (disposable install-repo E2E)
./scripts/smoke/e2e-sanity.sh --ci
./scripts/smoke/e2e-sanity.sh --with-loop
./scripts/smoke/e2e-sanity.sh --with-loop-standalone
./scripts/smoke/e2e-sanity.sh --with-loop-epic
./scripts/smoke/e2e-sanity.sh --with-loop --app-mode ui

# Archive / merge / cleanup lifecycle
./ralph-commit.sh
./ralph-sprint-commit.sh
./ralph-archive.sh
./ralph-cleanup.sh --force
```

## Key Files

- `ralph-prd.sh` - Interactive/non-interactive wrapper to create PRDs and convert to `prd.json`
- `ralph.sh` - The bash loop that spawns fresh Codex runs
- `ralph-prime.sh` - Auto-selects/uses active epic and primes `prd.json` for loop startup
- `ralph-sprint.sh` - Sprint container and active sprint management (`create/use/status/add-epics`)
- `ralph-epic.sh` - CLI to list/select/update epic order and status
- `ralph-archive.sh` - Archive run artifacts into sprint/standalone task archives and reset `prd.json`
- `ralph-commit.sh` - Validate completion, archive run, merge using mode-aware default target (epic -> sprint branch, standalone -> base branch), and sync epic status in epic mode
- `ralph-sprint-commit.sh` - Validate sprint completion, archive sprint-level state, and merge sprint branch into `master`/`main`
- `ralph-cleanup.sh` - Reset local Ralph artifacts without creating an archive
- `doctor.sh` - Sanity checks for a target repo
- `install.sh` - One-command installer into `scripts/ralph`
- `prompt.md` - Instructions given to each Codex run
- `prd.json.example` - Example PRD format
- `epics.json.example` - Example epic backlog template
- `prompts/*.md` - Optional reusable Codex command prompts installable to `~/.codex/prompts`
- `scripts/openspec/openspec-skill.sh` - Optional OpenSpec adapter that converts OpenSpec changes to `scripts/ralph/prd.json`

## Recommended Flow

1. Run `./doctor.sh`
2. If you changed local skills, run `./install.sh --install-skills` before PRD/prime runs
3. Confirm active sprint via `./ralph-sprint.sh status` (or set one with `use/create`)
4. Select next epic via `./ralph-epic.sh start-next`
5. Prime loop input via `./ralph-prime.sh`
6. Run loop via `./ralph.sh [max_iterations]`
7. Run `./ralph-commit.sh` to archive + merge using mode-aware defaults (epic -> sprint branch, standalone -> base branch); epic runs auto-mark matching epic `done`
8. Run `./ralph-sprint-commit.sh` when sprint epics are all done/abandoned

Epic lifecycle helpers:
- `./ralph-epic.sh abandon EPIC-XXX "reason"` keeps epic for reference but excludes it from next/start-next
- `./ralph-epic.sh remove EPIC-XXX` permanently removes an already-abandoned epic

Flowchart assets/source were removed because they are no longer valid for this repository. A new repo-specific flowchart may be added in the future.

## Patterns

- Each iteration spawns a fresh Codex run with clean context
- Memory persists via git history, `progress.txt`, and `prd.json`
- Stories should be small enough to complete in one context window
- Always update AGENTS.md with discovered patterns for future iterations
- `ralph-epic.sh` requires an active sprint; use `ralph-sprint.sh use <sprint-name>` first if needed.
- Fresh installs already seed `sprint-1`; create additional sprints only when needed.
- `ralph-archive.sh` has no `--help`; invoking it performs an archive run immediately.
- `ralph-epic.sh add ...` provides a non-interactive epic creation path; use it for automation.
- `ralph-commit.sh` and `ralph-sprint-commit.sh` delete merged source branches by default; pass `--keep` to retain them.
- `.active-prd` now includes explicit `baseBranch`; `ralph-commit.sh` should use it before fallback target inference.
- OpenSpec conversion is opt-in via `scripts/openspec/openspec-skill.sh` and is not invoked by `ralph.sh`; core Ralph loop behavior remains unchanged.
- Fresh-install epics should include `promptContext` so `ralph-prime.sh` can generate missing PRD markdown when starter `prdPaths` are not yet on disk.
- `ralph-sprint.sh status` should treat missing PRDs with `promptContext` as generatable warnings, and only fail for missing PRDs that cannot be generated.
- `ralph-sprint.sh status` now reports both `Active epic` and `Next epic` to avoid confusion when an epic is already active.
- Keep repo-specific Ralph behavior in `scripts/ralph/prompt.local.md` (and optional local helper scripts referenced there) so framework updates can refresh core files without disabling one-off project utilities.
- `ralph.sh` now supports marker-based local prompt injection: place `<!-- RALPH:LOCAL:<NAME> -->` in `prompt.md` and matching start/end blocks in `prompt.local.md`; empty local files are ignored and non-matching legacy local content falls back to append mode.

- Keep interactive wrappers minimal by default; provide `--detailed` mode for deeper prompts and CLI flags for non-interactive runs.
- Framework sanity smoke checks live in `scripts/smoke/e2e-sanity.sh`; local runs default to real Codex, CI runs with mock Codex for deterministic validation.
- Disposable smoke repos should configure a local git identity during setup so E2E runs do not depend on the developer having global `user.name` and `user.email` configured.
- `ralph-prd.sh --feature ... --no-questions` should stay non-interactive even when launched from a TTY; only open editor intake when the feature concept is missing or quick-question intake is still enabled.
- When the smoke harness runs under a TTY, explicitly redirect stdin from `/dev/null` for intentionally interactive wrappers (for example `ralph-sprint.sh create`) that are being used in automation-only setup steps.
- `ralph-verify.sh --targeted` should infer related tests for changed source files more broadly than exact basenames, and fall back to the full test suite when source files changed but no related targeted tests can be inferred.
