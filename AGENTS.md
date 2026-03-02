# Ralph Agent Instructions

## Overview

Ralph is an autonomous AI agent loop that runs Codex (`codex --yolo exec`) repeatedly until all PRD items are complete. Each iteration is a fresh Codex run with clean context.

## Commands

```bash
# Run the flowchart dev server
cd flowchart && npm run dev

# Build the flowchart
cd flowchart && npm run build

# Install skills globally for Codex
./install.sh --install-skills

# Install Ralph into a target project
./install.sh --project /path/to/your/project

# Generate and convert PRD into scripts/ralph/prd.json
./ralph-prd.sh

# Epic backlog sequencing helpers
./ralph-epic.sh list
./ralph-epic.sh start-next

# Prime prd.json for active/next eligible epic
./ralph-prime.sh

# Run Ralph loop (from your project that has prd.json)
./ralph.sh [max_iterations]
```

## Key Files

- `ralph-prd.sh` - Interactive/non-interactive wrapper to create PRDs and convert to `prd.json`
- `ralph.sh` - The bash loop that spawns fresh Codex runs
- `ralph-prime.sh` - Auto-selects/uses active epic and primes `prd.json` for loop startup
- `ralph-epic.sh` - CLI to list/select/update epic order and status
- `doctor.sh` - Sanity checks for a target repo
- `install.sh` - One-command installer into `scripts/ralph`
- `prompt.md` - Instructions given to each Codex run
- `prd.json.example` - Example PRD format
- `epics.json.example` - Example epic backlog template
- `flowchart/` - Interactive React Flow diagram explaining how Ralph works

## Recommended Flow

1. Run `./doctor.sh`
2. Select next epic via `./ralph-epic.sh start-next`
3. Prime loop input via `./ralph-prime.sh`
4. Run loop via `./ralph.sh [max_iterations]`
5. Run `./ralph-commit.sh` to archive + merge (it auto-marks the matching epic `done`)

Epic lifecycle helpers:
- `./ralph-epic.sh abandon EPIC-XXX "reason"` keeps epic for reference but excludes it from next/start-next
- `./ralph-epic.sh remove EPIC-XXX` permanently removes an already-abandoned epic

## Flowchart

The `flowchart/` directory contains an interactive visualization built with React Flow. It's designed for presentations - click through to reveal each step with animations.

To run locally:
```bash
cd flowchart
npm install
npm run dev
```

## Patterns

- Each iteration spawns a fresh Codex run with clean context
- Memory persists via git history, `progress.txt`, and `prd.json`
- Stories should be small enough to complete in one context window
- Always update AGENTS.md with discovered patterns for future iterations

- Keep interactive wrappers minimal by default; provide `--detailed` mode for deeper prompts and CLI flags for non-interactive runs.
