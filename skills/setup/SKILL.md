---
name: setup
description: "Install Ralph (Codex port) as Codex skills and configure a target project to run the Ralph loop. Triggers on: install ralph, setup ralph, configure ralph for project, ralph for codex setup, ralph install."
---

# Setup Ralph for Codex

Install Ralph skills, install Ralph runtime into a project, and run a smoke test.

## Non-Negotiables

- Install/refresh global skills before skill-driven PRD conversion flows.
- Run `install.sh` from this repo.
- Use an absolute target path for `--project`.
- Verify with `./scripts/ralph/doctor.sh` after install.
- Run at least one smoke iteration before real feature work.
- Keep project-specific checks in `scripts/ralph/prompt.md`.

## Ask Only If Missing

1. Target project root path?
2. Install skills globally (`~/.codex/skills`) or project-local only?
3. Start with smoke PRD or convert an existing PRD?

## Steps

### A) Install skills globally (recommended)

Run from this repo (where `install.sh` exists):

```bash
bash ./install.sh --install-skills
```

Copies all `skills/*` folders to `~/.codex/skills/`.
Re-run this after local skill edits so runtime behavior matches repo changes.

### B) Install Ralph into target project

```bash
bash ./install.sh --project /absolute/path/to/target-project
```

Installs `scripts/ralph/` with loop scripts, helpers, templates, and optional smoke files if missing.

### C) Verify install

From target project root:

```bash
./scripts/ralph/doctor.sh
```

### D) Smoke run (recommended)

From target project root:

```bash
./scripts/ralph/ralph.sh 1
```

Expected:

- `RALPH_SMOKE.txt` created
- Commit like `feat: US-001 - ...`
- `passes: true` for first story in `scripts/ralph/prd.json`
- Progress appended to `scripts/ralph/progress.txt`
- Exit code `0`

### E) Real feature workflow

1. Create markdown PRD in `tasks/` using the PRD skill.
2. Convert it using the Ralph skill into `scripts/ralph/prd.json`.
3. Run:

```bash
./scripts/ralph/ralph.sh 10
```

## Sprint Story Sequencing

```bash
# Create a sprint and add stories
./scripts/ralph/ralph-sprint.sh create sprint-1
./scripts/ralph/ralph-story.sh add --title "My Story" --goal "..." --prompt-context "..."

# Start each story and run its tasks
./scripts/ralph/ralph-story.sh start-next
./scripts/ralph/ralph-task.sh

# Repeat start-next + ralph-task.sh for each story
```

After all stories complete:

```bash
./scripts/ralph/ralph-sprint-commit.sh
# use --keep to retain merged sprint branch
# use --skip-regression to bypass pre-merge regression gate
```

Standalone PRD flow (single feature, no sprint):

```bash
./scripts/ralph/ralph-prd.sh
./scripts/ralph/ralph-prime.sh
./scripts/ralph/ralph.sh 10
./scripts/ralph/ralph-commit.sh
# use --keep to retain merged feature branch
```

## Notes

- Add project-specific lint/test/typecheck commands to `scripts/ralph/prompt.md`.
- Keep `scripts/ralph/.iteration-log*.txt` and `scripts/ralph/.iteration-handoff*.json` ignored (installer updates `.gitignore`).
