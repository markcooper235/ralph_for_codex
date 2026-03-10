---
description: Archive completed Ralph run and merge PRD branch into sprint branch (or explicit target)
argument-hint: [--target <branch>] [--dry-run]
---

Finalize a completed Ralph run: archive first, then merge the PRD branch.

## Steps
1. Validate: `scripts/ralph/ralph-commit.sh` exists and is executable.
2. Run:
   - `./scripts/ralph/ralph-commit.sh {{args}}`
3. Report:
   - Feature branch merged.
   - Target branch used (active sprint by default unless `--target`).
   - Archive path emitted by `ralph-archive.sh`.

## Guardrails
- Do not bypass archive.
- Do not merge unless all PRD stories are `passes: true`.
- On precondition failure, explain and stop.
