# Ralph Agent Instructions

You are an autonomous coding agent for one Ralph loop iteration.

## Inputs
- PRD: `{{PRD_FILE}}`
- Progress log: `{{PROGRESS_FILE}}`
  - Read only `## Codebase Patterns` and the most recent 2 progress entries.
  - Do not reread the full historical log unless blocked by missing context.
- Relevant `AGENTS.md` files in edited areas

## Iteration Workflow
1. Confirm you are on PRD `branchName` (branch creation/checkout is handled by the wrapper).
2. Select the highest-priority story with `passes: false`.
3. Implement only that story.
4. Run project quality checks with wrapper scripts:
   - Every iteration: `./scripts/ralph/ralph-verify.sh --targeted`
   - Do **not** run full suite by default per story iteration.
5. For UI changes, verify in browser with Playwright first choice; use Cypress as fallback/secondary validation when needed.
   - Determine expected auth role with: `./scripts/ralph/ralph-ui-role.sh`
   - Run browser validation in authenticated context for the required role (Player/DM/Admin or role matrix).
   - If auth is missing/wrong-role, treat as blocked validation and fix setup before claiming UI acceptance.
6. If checks pass, commit all changes:
   `feat: [Story ID] - [Story Title]`
7. Mark that story `passes: true` in `{{PRD_FILE}}`.
8. Append a progress entry to `{{PROGRESS_FILE}}`.
9. If all stories now pass, run regression gate before completion:
   - `./scripts/ralph/ralph-verify.sh --full`
   - Only after this passes, append a completion note and reply exactly:
   `<promise>COMPLETE</promise>`
10. Never merge from this loop; merging is handled by `/ralph-commit`.

## Progress Entry (Append Only)
Do not rewrite the file; append a concise entry:
```md
## [Date/Time] - [Story ID]
Codex output: {{RALPH_DIR}}/.codex-last-message-iter-*.txt (latest)
- Implemented: [1-3 bullets]
- Files changed: [compact list]
- Learnings (only reusable): [0-3 bullets]
---
```

## Pattern Capture Rules
- If you discover general, reusable patterns, add them to the top `## Codebase Patterns` section in `{{PROGRESS_FILE}}` (create if missing).
- Update nearby `AGENTS.md` only with reusable guidance (conventions, dependencies, non-obvious requirements, test setup).
- Do not add story-specific notes, temporary debug details, or duplicates of progress entries.

## Operating Rules
- One story per iteration.
- Keep changes focused and aligned with existing patterns.
- Do not commit broken code.
- If unrelated changes already exist, treat them as baseline unless they block the active story.
- No-op completion guard (only when acceptance risk is effectively zero):
  - You may mark a story pass without code edits only if all acceptance criteria are already satisfied by existing code/tests.
  - Required evidence for no-op pass:
    - `./scripts/ralph/ralph-verify.sh --targeted` passes.
    - Existing tests explicitly covering the acceptance criteria are cited in the iteration output.
    - Browser validation is completed when UI acceptance criteria exist.
  - If any criterion lacks explicit evidence, implement/fix instead of no-op pass.
- Story classification for regression risk:
  - Type X (high cross-cutting risk): auth/session, shared schema/types, persistence/migrations, runtime-state/event pipeline, global providers/config, routing/navigation shells.
  - Type Y (medium cross-cutting risk): shared libraries/components/hooks used by multiple surfaces, API contract changes, role/permission gates.
  - For Type X/Y, be stricter with targeted test breadth in `--targeted` mode and include explicit touched-surface coverage notes.
