---
description: Archive the current Ralph run (copy prd.json and progress.txt into scripts/ralph/archive)
argument-hint: none
---

Archive the current Ralph run for the active project.

**Steps**

1. Validate this is a Ralph-enabled repo:
   - Confirm `scripts/ralph` exists.
   - Confirm at least one of `scripts/ralph/prd.json` or `scripts/ralph/progress.txt` exists.

2. Run the archive command:
   ```bash
   ./scripts/ralph/ralph-archive.sh
   ```

3. Report results:
   - Archive destination path printed by the command.
   - Whether `prd.json` and `progress.txt` were copied.

**Guardrails**
- Do not delete existing archive folders.
- If `scripts/ralph/ralph-archive.sh` is missing, explain what is missing and stop.
