---
description: Archive the current Ralph run into scripts/ralph/tasks/archive
argument-hint: none
---

Archive the current Ralph run.

## Steps
1. Validate repo:
   - `scripts/ralph` exists.
   - At least one of `scripts/ralph/prd.json` or `scripts/ralph/progress.txt` exists.
2. Run:
   - `./scripts/ralph/ralph-archive.sh`
3. Report:
   - Archive destination path.
   - Whether `prd.json` and `progress.txt` were copied.

## Guardrails
- Do not delete existing archive folders.
- If `scripts/ralph/ralph-archive.sh` is missing, explain and stop.
