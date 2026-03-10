---
description: Create a change and generate all artifacts needed for implementation in one go
argument-hint: command arguments
---

Fast-forward artifact creation until the change is implementation-ready.

## Input
- `/opsx:ff <name-or-description>`.
- If missing input, ask user what they want to build and derive kebab-case name.

## Steps
1. Create change:
   - `openspec new change "<name>"`
2. Load status:
   - `openspec status --change "<name>" --json`
   - Use `applyRequires` and `artifacts`.
3. Create artifacts in dependency order until all `applyRequires` are `done`:
   - Track progress with **TodoWrite**.
   - For each `ready` artifact:
     - `openspec instructions <artifact-id> --change "<name>" --json`
     - Read dependency artifacts.
     - Write artifact using `template` + `instruction`.
     - Use `context` and `rules` as constraints only (do not copy into artifact).
     - Confirm file exists.
     - Re-run status.
4. If critical context is missing, ask with **AskUserQuestion**, then continue.
5. Show final status:
   - `openspec status --change "<name>"`

## Output
- Change name/location.
- Artifacts created.
- Confirmation that implementation can start.
- Suggest `/opsx:apply`.

## Guardrails
- Complete all artifacts required by schema `apply.requires`.
- Respect dependency order.
- If change already exists, ask whether to continue or create a new name.
