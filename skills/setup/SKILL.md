---
name: setup-ralph-for-codex
description: "Install Ralph (Codex port) as Codex skills and configure a target project to run the Ralph loop. Triggers on: install ralph, setup ralph, configure ralph for project, ralph for codex setup, ralph install."
---

# Setup Ralph for Codex

This skill helps you:
1) Install this repo’s skills into Codex (`~/.codex/skills`)
2) Install/configure Ralph in a target project (`scripts/ralph/`)
3) Run a quick smoke test

## What to ask the user first (only if needed)

1. Where is the target project root directory?
2. Do they want skills installed globally (recommended) or project-local only?
3. Do they want to start with the included smoke PRD, or convert an existing PRD?

## Steps

### A) Install skills globally (recommended)

Run from **this repo** (where `install.sh` exists), or provide the absolute path:

```bash
bash ./install.sh --install-skills
```

This copies all folders in `skills/` into `~/.codex/skills/`.

### B) Install Ralph into the target project

From **this repo**, run:

```bash
bash ./install.sh --project /absolute/path/to/target-project
```

This installs into `/absolute/path/to/target-project/scripts/ralph/`:
- `ralph.sh` (loop runner)
- `doctor.sh` (sanity checks)
- `prompt.md` (agent instructions)
- `prd.json.example`
- `epics.json.example`
- `ralph-epic.sh` (epic sequencing helper)
- `ralph-prime.sh` (auto-prime helper)
- (optional) smoke `prd.json` + `progress.txt` if missing
- `epics.json` if missing

### C) Verify installation

From the target project root:

```bash
./scripts/ralph/doctor.sh
```

### D) Smoke-run (recommended)

From the target project root:

```bash
./scripts/ralph/ralph.sh 1
```

Expected outcome:
- Creates `RALPH_SMOKE.txt` in repo root (from the smoke PRD)
- Creates a commit `feat: US-001 - ...`
- Sets `passes: true` in `scripts/ralph/prd.json`
- Appends to `scripts/ralph/progress.txt`
- Exits `0` (loop complete)

### E) Configure a real feature workflow

1) Use the PRD skill to write a markdown PRD (saved in `tasks/`):

“Load the prd skill and create a PRD for …”

2) Convert it to Ralph JSON:

“Load the ralph skill and convert tasks/prd-xxx.md to scripts/ralph/prd.json”

3) Run the loop:

```bash
./scripts/ralph/ralph.sh 10
```

### Epic sequencing before each loop

```bash
./scripts/ralph/ralph-epic.sh list
./scripts/ralph/ralph-epic.sh next
./scripts/ralph/ralph-epic.sh start-next
./scripts/ralph/ralph-prime.sh
```

After an epic completes:

```bash
./scripts/ralph/ralph-epic.sh set-status EPIC-001 done
```

## Notes

- If the project has lint/test/typecheck commands, add them to `scripts/ralph/prompt.md` (project-specific).
- Keep `scripts/ralph/.codex-last-message*.txt` ignored; `install.sh` adds `.gitignore` entries automatically.
