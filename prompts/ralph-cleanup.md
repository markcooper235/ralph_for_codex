---
description: Cleanup active Ralph run-state files without archiving
argument-hint: none
---

Clean active Ralph run-state files without archiving.

## Steps
1. Validate repo: `scripts/ralph` exists.
2. Run:
   - `./scripts/ralph/ralph-cleanup.sh`
3. Report removed files (when present), for example:
   - `scripts/ralph/progress.txt`
   - `scripts/ralph/.last-branch`
   - `scripts/ralph/.codex-last-message.txt`
   - `scripts/ralph/.codex-last-message-iter-*.txt`

## Guardrails
- Do not create archives.
- If `scripts/ralph/ralph-cleanup.sh` is missing, explain and stop.
