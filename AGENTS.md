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

# Prime prd.json for active/next eligible epic
./ralph-prime.sh

# Run Ralph loop (from your project that has prd.json)
./ralph.sh [max_iterations]

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
- `ralph-commit.sh` - Validate completion, archive run, merge epic branch into sprint branch, and sync epic status
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
2. Confirm active sprint via `./ralph-sprint.sh status` (or set one with `use/create`)
3. Select next epic via `./ralph-epic.sh start-next`
4. Prime loop input via `./ralph-prime.sh`
5. Run loop via `./ralph.sh [max_iterations]`
6. Run `./ralph-commit.sh` to archive + merge to sprint branch (it auto-marks the matching epic `done`)
7. Run `./ralph-sprint-commit.sh` when sprint epics are all done/abandoned

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
- `ralph-archive.sh` has no `--help`; invoking it performs an archive run immediately.
- OpenSpec conversion is opt-in via `scripts/openspec/openspec-skill.sh` and is not invoked by `ralph.sh`; core Ralph loop behavior remains unchanged.
- Fresh-install epics should include `promptContext` so `ralph-prime.sh` can generate missing PRD markdown when starter `prdPaths` are not yet on disk.
- `ralph-sprint.sh status` should treat missing PRDs with `promptContext` as generatable warnings, and only fail for missing PRDs that cannot be generated.
- `ralph-sprint.sh status` now reports both `Active epic` and `Next epic` to avoid confusion when an epic is already active.

- Keep interactive wrappers minimal by default; provide `--detailed` mode for deeper prompts and CLI flags for non-interactive runs.
