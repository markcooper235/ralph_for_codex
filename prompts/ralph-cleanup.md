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
   - `scripts/ralph/.iteration-log-latest.txt`
   - `scripts/ralph/.iteration-log-iter-*.txt`
   - `scripts/ralph/.iteration-handoff-latest.json`
   - `scripts/ralph/.iteration-handoff-iter-*.json`

## Guardrails
- Do not create archives.
- If `scripts/ralph/ralph-cleanup.sh` is missing, explain and stop.
