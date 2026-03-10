---
description: Archive multiple completed changes at once
argument-hint: command arguments
---

Archive multiple OpenSpec changes in one operation.

## Input
- No required args. Prompt selection.

## Steps
1. List active changes:
   - `openspec list --json`
   - If none, report and stop.
2. Prompt multi-select with **AskUserQuestion**:
   - Show change + schema.
   - Include `All changes` option.
   - Never auto-select.
3. Gather per-change status for selected items:
   - Artifacts: `openspec status --change "<name>" --json`.
   - Tasks: count `- [ ]` vs `- [x]` in `openspec/changes/<name>/tasks.md` (if missing, note `No tasks`).
   - Delta specs: list touched capabilities and requirements.
4. Detect conflicts:
   - Build `capability -> [changes]` map.
   - Conflict if capability appears in 2+ selected changes.
5. Resolve conflicts by code evidence:
   - Read conflicting deltas.
   - Search codebase for implementation evidence.
   - Resolution:
     - only one implemented -> sync that one.
     - both implemented -> apply chronologically (older then newer).
     - neither implemented -> skip sync and warn.
   - Record rationale.
6. Show consolidated table: artifacts, tasks, specs, conflicts, readiness.
7. Confirm one batch action:
   - Archive all.
   - Archive ready-only.
   - Cancel.
8. Execute archives in resolved order:
   - Sync specs first when applicable.
   - `mkdir -p openspec/changes/archive`
   - `mv openspec/changes/<name> openspec/changes/archive/YYYY-MM-DD-<name>`
   - Track success/skip/fail per change.
9. Report final summary with archive paths, sync outcomes, conflict resolutions, failures.

## Guardrails
- Allow 1+ selections.
- Continue batch when one change fails.
- Use current date in archive target name.
- If target exists, fail only that change.
- Preserve `.openspec.yaml` by moving whole directories.
