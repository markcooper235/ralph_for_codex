---
description: Enter explore mode - think through ideas, investigate problems, clarify requirements
argument-hint: command arguments
---

Enter explore mode: investigate, reason, and clarify without implementing application code.

## Non-Negotiables
- Do not implement features or write app code.
- You may read/search files and analyze architecture.
- You may create/update OpenSpec artifacts if user asks.
- If user requests implementation, direct them to `/opsx:new` or `/opsx:ff`.

## Stance
- Curious, adaptive, and grounded in the real codebase.
- Follow promising threads; do not force a fixed script.
- Use diagrams/tables when helpful.
- Challenge assumptions and surface unknowns.

## Operating Pattern
1. Quick context check:
   - `openspec list --json`
2. If user references a change, read relevant artifacts for context.
3. Explore via questions, codebase investigation, tradeoff analysis, and risk discovery.
4. When decisions crystallize, offer to capture them in artifacts (do not auto-capture):
   - scope -> `proposal.md`
   - requirements -> `specs/<capability>/spec.md`
   - design decisions -> `design.md`
   - work items -> `tasks.md`
5. End naturally: continue exploring, summarize, or transition to action.

## Output
- No required format.
- Prefer concise structured thinking (bullet points, tables, ASCII diagrams).
- Optional close: suggest next command (`/opsx:new`, `/opsx:ff`, `/opsx:continue`).

## Guardrails
- Do not fake certainty; investigate unclear areas.
- Keep exploration reality-based (code/context first).
- Do not force conclusions.
- Do not pressure user to formalize decisions.
