---
description: Archive completed Ralph run and merge PRD branch into master/main
argument-hint: [--target master|main] [--dry-run]
---

Finalize a completed Ralph run by archiving artifacts first, then merging the PRD branch.

**Steps**

1. Validate this is a Ralph-enabled repo:
   - Confirm `scripts/ralph/ralph-commit.sh` exists and is executable.

2. Run finalize command:
   ```bash
   ./scripts/ralph/ralph-commit.sh {{args}}
   ```

3. Report results:
   - Feature branch merged
   - Target branch used (`master` or `main`)
   - Archive folder path emitted by `ralph-archive.sh`

**Guardrails**
- Do not bypass archive step.
- Do not merge if PRD stories are not all `passes: true`.
- If preconditions fail, explain the failure and stop.
