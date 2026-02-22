---
description: Cleanup active Ralph run-state files without archiving
argument-hint: none
---

Clean up current Ralph run-state files for the active project.

**Steps**

1. Validate this is a Ralph-enabled repo:
   - Confirm `scripts/ralph` exists.

2. Run cleanup command:
   ```bash
   ./scripts/ralph/ralph-cleanup.sh
   ```

3. Report results:
   - Which files were removed (if present), such as:
     - `scripts/ralph/progress.txt`
     - `scripts/ralph/.last-branch`
     - `scripts/ralph/.codex-last-message.txt`
     - `scripts/ralph/.codex-last-message-iter-*.txt`

**Guardrails**
- Cleanup must not create archives.
- If `scripts/ralph/ralph-cleanup.sh` is missing, explain what is missing and stop.
