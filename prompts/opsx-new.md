---
description: Start a new change using the experimental artifact workflow (OPSX)
argument-hint: command arguments
---

Start a new OpenSpec change and prepare the first artifact, then stop.

## Input
- `/opsx:new <name-or-description>`.
- If missing, ask what the user wants to build and derive kebab-case name.

## Steps
1. Choose schema:
   - Use default schema unless user explicitly requests another.
   - If user asks available workflows, run `openspec schemas --json` and let them choose.
2. Create change:
   - `openspec new change "<name>"` (add `--schema <name>` only when explicitly chosen).
3. Show status:
   - `openspec status --change "<name>"`
4. Find first `ready` artifact and fetch instructions:
   - `openspec instructions <artifact-id> --change "<name>"`
5. Stop and wait for user direction.

## Output
- Change name/location.
- Schema/workflow and artifact sequence.
- Current progress (`0/N` style).
- First artifact template/instructions.
- Prompt to run `/opsx:continue`.

## Guardrails
- Do not create artifacts in this command.
- If name is invalid, ask for valid kebab-case.
- If change exists, suggest `/opsx:continue`.
