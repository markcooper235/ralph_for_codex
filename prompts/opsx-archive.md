---
description: Archive a completed change in the experimental workflow
argument-hint: command arguments
---

Archive a completed OpenSpec change.

## Input
- Optional change name: `/opsx:archive <name>`.
- If omitted: prompt selection from `openspec list --json` using **AskUserQuestion**.
- Never guess/auto-select.

## Steps
1. Validate artifacts:
   - `openspec status --change "<name>" --json`
   - If any artifact is not `done`, show warning and request confirmation.
2. Validate tasks:
   - Read tasks file (if present) and count `- [ ]` vs `- [x]`.
   - If incomplete tasks exist, warn and request confirmation.
3. Assess delta spec sync:
   - If `openspec/changes/<name>/specs/` has no deltas, continue.
   - If deltas exist, compare with `openspec/specs/<capability>/spec.md`, summarize adds/modifies/removes/renames.
   - Prompt:
     - Changes needed: `Sync now (recommended)` or `Archive without syncing`.
     - Already synced: `Archive now`, `Sync anyway`, or `Cancel`.
   - If sync chosen, execute `/opsx:sync` logic, then continue.
4. Archive change:
   - `mkdir -p openspec/changes/archive`
   - Move to `openspec/changes/archive/YYYY-MM-DD-<name>`.
   - If target exists, fail and report options.
5. Report summary: change, schema, archive path, spec sync status, and any warning conditions.

## Guardrails
- Do not block archive on warnings; confirm and proceed when user approves.
- Always run sync assessment when delta specs exist.
- Preserve `.openspec.yaml` by moving the full change directory.
- Show clear final status.
