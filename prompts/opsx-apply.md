---
description: Implement tasks from an OpenSpec change (Experimental)
argument-hint: command arguments
---

Implement tasks for an OpenSpec change.

## Input
- Optional change name: `/opsx:apply <name>`.
- If omitted: infer from context when clear; auto-select only if exactly one active change; otherwise prompt with `openspec list --json` and **AskUserQuestion**.
- Always announce: `Using change: <name>` and how to override.

## Steps
1. Check status:
   - `openspec status --change "<name>" --json`
   - Capture `schemaName` and artifact/task context.
2. Get apply instructions:
   - `openspec instructions apply --change "<name>" --json`
   - Use returned `contextFiles`, task progress, and dynamic instruction.
3. Handle instruction state:
   - `blocked`: explain missing artifacts, suggest `/opsx:continue`, stop.
   - `all_done`: report complete, suggest archive, stop.
   - otherwise continue.
4. Read all files listed in `contextFiles`.
5. Show current progress: schema, `N/M` complete, remaining tasks, dynamic instruction.
6. Implement pending tasks in order:
   - Announce current task.
   - Make focused code changes.
   - Mark task done in tasks file (`- [ ]` -> `- [x]`) immediately after completion.
   - Continue until done or blocked.
7. Pause and ask if task is unclear, design conflict appears, error/blocker occurs, or user interrupts.
8. On stop/completion, report tasks completed this session and overall progress; suggest archive if all done.

## Output
- During work: task-by-task status.
- On completion: change, schema, final `N/M`, completed tasks.
- On pause: issue summary plus options.

## Guardrails
- Keep going until done or blocked.
- Read `contextFiles` before implementation.
- Keep edits minimal and scoped to current task.
- Do not guess on ambiguous requirements.
- Use CLI-provided `contextFiles`; do not assume paths.
- This action is fluid: artifact updates can be proposed when implementation reveals issues.
