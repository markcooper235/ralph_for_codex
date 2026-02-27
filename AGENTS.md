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

# Run Ralph (from your project that has prd.json)
./ralph.sh [max_iterations]
```

## Key Files

- `ralph.sh` - The bash loop that spawns fresh Codex runs
- `doctor.sh` - Sanity checks for a target repo
- `install.sh` - One-command installer into `scripts/ralph`
- `prompt.md` - Instructions given to each Codex run
- `prd.json.example` - Example PRD format
- `flowchart/` - Interactive React Flow diagram explaining how Ralph works

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
