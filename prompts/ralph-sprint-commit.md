---
description: Finalize active sprint by validating epic completion, archiving sprint state, and merging sprint branch
argument-hint: [--target master|main] [--dry-run]
---

Close out the active sprint.

## Steps
1. Validate: `scripts/ralph/ralph-sprint-commit.sh` exists and is executable.
2. Run:
   - `./scripts/ralph/ralph-sprint-commit.sh {{args}}`
3. Report:
   - Sprint merged.
   - Target branch used.
   - Sprint archive path.

## Guardrails
- Do not run while sprint still has active/planned epics.
- Do not bypass sprint archive.
- On precondition failure, explain and stop.
