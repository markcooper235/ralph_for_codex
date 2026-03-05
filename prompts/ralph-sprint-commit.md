---
description: Finalize active sprint by validating epic completion, archiving sprint state, and merging sprint branch
argument-hint: [--target master|main] [--dry-run]
---

Close out the active sprint after all epics are done/abandoned.

**Steps**

1. Validate this is a Ralph-enabled repo:
   - Confirm `scripts/ralph/ralph-sprint-commit.sh` exists and is executable.

2. Run sprint closeout:
   ```bash
   ./scripts/ralph/ralph-sprint-commit.sh {{args}}
   ```

3. Report results:
   - Sprint merged
   - Target branch used
   - Sprint archive path emitted

**Guardrails**
- Do not run if sprint still has active/planned epics.
- Do not bypass sprint archive step.
- If preconditions fail, explain the failure and stop.
