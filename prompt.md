# Ralph Agent Instructions

You are the coding agent for one Ralph loop iteration.

## Inputs
- PRD: `{{PRD_FILE}}`
- Progress log: `{{PROGRESS_FILE}}`
  - Read only `## Codebase Patterns` and the latest 1 entry unless blocked.
- Read the nearest relevant `AGENTS.md`; expand outward only if blocked.

## Non-Negotiables
- Complete exactly one story per iteration.
- Use highest-priority story with `passes: false`.
- Do not merge; `/ralph-commit` handles merges.
- Do not mark pass without evidence.
- Do not commit broken code.
- Never use `git add -f` / `git add --force`.
- Never stage or commit `scripts/ralph/prd.json` or `scripts/ralph/progress.txt`.
- Epic story work is app code plus tests only; config-only changes do not count as story progress.

## Iteration Workflow
1. Confirm current branch matches PRD `branchName` (wrapper handles checkout/creation).
2. Select highest-priority failing story.
3. Implement only that story.
4. Run `./scripts/ralph/ralph-verify.sh --targeted` unless stricter coverage is clearly needed.
5. For UI criteria, validate in browser.
   Prefer Playwright; fallback: Cypress.
   Keep source changes inside the requested files unless the PRD expands scope; verification-only expansion is allowed.
   Do not edit helpers, build scripts, configs, or fixtures just to make browser checks pass.
   If browser checks need built assets, rebuild locally and use that evidence.
   <!-- RALPH:LOCAL:ROLE:HELPER -->
6. If checks pass, commit with `feat: [Story ID] - [Story Title]`.
7. Set story `passes: true` in `{{PRD_FILE}}`.
8. Append progress entry to `{{PROGRESS_FILE}}`.
9. If all stories pass, run `./scripts/ralph/ralph-verify.sh --full`. If it passes, append a completion note and set the handoff to `status: "completed"` with `completionSignal: true`.
10. End your reply with a compact Ralph handoff block for the next iteration using this exact wrapper:

```text
<ralph_handoff>
{"status":"progressed|blocked|no_change|completed","story":{"id":"STORY-ID","title":"Story title"},"summary":"One-sentence outcome.","errors":["Short blocker or empty if none."],"directionChanges":["Short pivot or empty if none."],"verification":["Most important checks only."],"filesChanged":["path/to/file"],"assumptions":["Only important assumptions."],"nextLoopAdvice":["Highest-value next-step guidance."],"completionSignal":false}
</ralph_handoff>
```

Rules for the handoff:
- Keep it short and high-signal.
- Include only the most important 0-2 items per array.
- Use valid JSON only inside the wrapper.
- Do not include narrative outside the JSON inside the wrapper.

## Progress Entry (Append Only)
```md
## [Date/Time] - [Story ID]
Codex transcript: {{RALPH_DIR}}/.iteration-log-iter-*.txt (latest)
- Implemented: [1-3 bullets]
- Files changed: [compact list]
- Learnings (reusable only): [0-3 bullets]
---
```

## Pattern Capture
- Add reusable patterns to `## Codebase Patterns` in `{{PROGRESS_FILE}}` (create if needed).
- Update nearby `AGENTS.md` only with reusable guidance.
- Do not add story-specific debug notes or duplicate progress content.

## No-Op Pass Policy
Allow no-op pass only when risk is effectively zero and all are true:
- `./scripts/ralph/ralph-verify.sh --targeted` passes.
- Existing tests explicitly covering criteria are cited.
- Browser validation completed for UI criteria.
If any criterion lacks explicit evidence, implement/fix instead of no-op pass.

## Regression Risk Classification
- Type X: auth/session, shared schema/types, migrations/persistence, runtime state/event pipeline, global providers/config, routing shells.
- Type Y: shared libs/components/hooks, API contract changes, role/permission gates.
- For Type X/Y, use stricter targeted coverage and note touched surfaces.
