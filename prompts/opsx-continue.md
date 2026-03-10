---
description: Continue working on a change - create the next artifact (Experimental)
argument-hint: command arguments
---

Continue a change by creating the next ready artifact.

## Input
- Optional change name: `/opsx:continue <name>`.
- If omitted: list recent changes via `openspec list --json` and prompt with **AskUserQuestion**.
- Show top 3-4 recent items with name, schema, status, and recency.
- Mark most recent as recommended.
- Never auto-select.

## Steps
1. Check status:
   - `openspec status --change "<name>" --json`
   - Use `schemaName`, `artifacts`, `isComplete`.
2. If `isComplete: true`:
   - Report all artifacts complete.
   - Suggest `/opsx:apply` or `/opsx:archive`.
   - Stop.
3. If any artifact is `ready`:
   - Pick first `ready` artifact.
   - Get instructions:
     - `openspec instructions <artifact-id> --change "<name>" --json`
   - Use `template`, `instruction`, `outputPath`, `dependencies`.
   - Treat `context` and `rules` as constraints only; do not copy them into output.
   - Read dependency artifacts.
   - Create artifact at `outputPath`.
   - Stop after creating exactly one artifact.
4. If none are ready:
   - Report blocked state and suggest issue checks.
5. Show updated progress:
   - `openspec status --change "<name>"`

## Output
- Artifact created.
- Workflow schema.
- Current progress (`N/M`).
- Newly unlocked artifacts.
- Prompt to run `/opsx:continue` again.

## Guardrails
- Create one artifact per invocation.
- Never skip order/dependencies.
- Ask user only when context is unclear.
- Verify artifact file exists after writing.
- Follow schema artifact sequence from CLI output.
