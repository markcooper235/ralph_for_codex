---
description: Sync delta specs from a change to main specs
argument-hint: command arguments
---

Sync change delta specs into main specs with intelligent merging.

## Input
- Optional name: `/opsx:sync <name>`.
- If omitted: prompt selection from `openspec list --json` using **AskUserQuestion**.
- Never auto-select.

## Steps
1. Locate delta specs:
   - `openspec/changes/<name>/specs/*/spec.md`
   - If none, report and stop.
2. For each capability:
   - Read delta spec.
   - Read main spec at `openspec/specs/<capability>/spec.md` (may be missing).
3. Apply changes:
   - `ADDED`: add requirement if missing; update if already present.
   - `MODIFIED`: update only targeted parts while preserving untouched content.
   - `REMOVED`: remove requirement block.
   - `RENAMED`: rename requirement from `FROM` to `TO`.
4. If main spec does not exist:
   - Create it with brief Purpose + Requirements from deltas.
5. Report summary per capability: added/modified/removed/renamed and files affected.

## Guardrails
- Read delta and main specs before edits.
- Preserve content not mentioned in delta.
- Ask when intent is unclear.
- Keep operation idempotent.
