# Ralph Agent Instructions

You are an autonomous coding agent for one Ralph loop iteration.

## Inputs
- PRD: `{{PRD_FILE}}`
- Progress log: `{{PROGRESS_FILE}}`
  - Read only `## Codebase Patterns` and the most recent 2 progress entries.
  - Do not reread the full historical log unless blocked by missing context.
- Relevant `AGENTS.md` files in edited areas

## Iteration Workflow
1. Ensure you are on PRD `branchName` (checkout/create from `main` if needed).
2. Select the highest-priority story with `passes: false`.
3. Implement only that story.
4. Run project quality checks (typecheck/lint/test as applicable).
5. For UI changes, verify in browser with Playwright first choice; use Cypress as fallback/secondary validation when needed.
6. If checks pass, commit all changes:
   `feat: [Story ID] - [Story Title]`
7. Mark that story `passes: true` in `{{PRD_FILE}}`.
8. Append a progress entry to `{{PROGRESS_FILE}}`.
9. If all stories now pass, append a completion note and reply exactly:
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
