---
description: Guided onboarding - walk through a complete OpenSpec workflow cycle with narration
argument-hint: command arguments
---

Guide a first-time user through a full OpenSpec cycle with real work and light teaching.

## Non-Negotiables
- Use a real task from the current codebase.
- Follow full lifecycle: explore -> new -> proposal -> specs -> design -> tasks -> apply -> archive -> recap.
- Pause at key checkpoints for user confirmation.
- Keep implementation narration concise.
- Handle early exits gracefully.

## Preflight
1. Check initialization:
   - `openspec status --json 2>&1 || echo "NOT_INITIALIZED"`
2. If not initialized: tell user to run `openspec init`, then stop.

## Flow
1. Welcome and explain the cycle (about 15-20 minutes).
2. Task selection:
   - Scan for small wins (TODO/FIXME, missing validation/tests, swallowed errors, debug leftovers, obvious type issues).
   - Optionally inspect recent git history.
   - Present 3-4 scoped options with location, size estimate, and why.
   - If none found, ask user for a small task idea.
   - If chosen task is too large, suggest slicing smaller; allow override.
3. Explore demo:
   - Briefly investigate relevant code and share quick analysis/diagram.
   - Explain that `/opsx:explore` is for thinking before implementation.
   - Pause for acknowledgment.
4. Create change:
   - Explain what a change container is.
   - Run `openspec new change "<derived-name>"`.
   - Show where artifacts live.
5. Proposal phase:
   - Draft proposal (`Why`, `What Changes`, `Capabilities`, `Impact`).
   - Ask for approval, revise if needed, then save to proposal path from instructions.
6. Specs phase:
   - Create capability spec file(s) using requirement/scenario format (`WHEN/THEN/AND`).
   - Save under `openspec/changes/<name>/specs/<capability>/spec.md`.
7. Design phase:
   - Draft concise design (`Context`, `Goals/Non-Goals`, key `Decisions`).
   - Save to `design.md`.
8. Tasks phase:
   - Generate ordered checkbox tasks from specs/design.
   - Confirm readiness, then save `tasks.md`.
9. Apply phase:
   - Implement tasks one-by-one.
   - Mark each task done in `tasks.md` immediately.
   - Keep references to artifacts practical and brief.
10. Archive phase:
   - Explain archive purpose.
   - Run `openspec archive "<name>"` and show archive path.
11. Recap:
   - Summarize completed cycle.
   - Provide quick command reference and suggested next commands.

## Checkpoint Pattern
At key transitions, use: Explain -> Do -> Show -> Pause.
Required pauses: after explore demo, after proposal draft, after task plan, and before/after archive.

## Early Exit Handling
- If user pauses/stops mid-flow:
  - Show current saved location.
  - Suggest `/opsx:continue <name>` or `/opsx:apply <name>` when applicable.
- If user asks for quick reference only:
  - Provide concise command table and stop.

## Guardrails
- Do not skip phases in onboarding mode.
- Avoid over-lecturing; prioritize momentum.
- Use realistic scope and concrete file references.
- Respect user choices, including opting out.
