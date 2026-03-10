---
description: Verify implementation matches change artifacts before archiving
argument-hint: command arguments
---

Verify implementation against OpenSpec artifacts before archive.

## Input
- Optional change name: `/opsx:verify <name>`.
- If omitted: prompt selection from `openspec list --json` using **AskUserQuestion**.
- Show schema and in-progress indicators; never auto-select.

## Steps
1. Load status/context:
   - `openspec status --change "<name>" --json`
   - `openspec instructions apply --change "<name>" --json`
   - Read all available `contextFiles`.
2. Build report across three dimensions:
   - Completeness
   - Correctness
   - Coherence
3. Verify completeness:
   - Tasks: parse `- [ ]` vs `- [x]`; incomplete tasks are CRITICAL.
   - Specs: extract requirements and check likely implementation evidence; missing requirements are CRITICAL.
4. Verify correctness:
   - Map requirements/scenarios to implementation evidence and tests.
   - Divergence or uncovered scenarios are WARNING by default.
5. Verify coherence:
   - Check design adherence when `design.md` exists.
   - Check consistency with project patterns.
   - Pattern issues are usually SUGGESTION unless severe.
6. Produce report with:
   - Summary scorecard table.
   - Issues grouped by CRITICAL/WARNING/SUGGESTION.
   - Specific recommendations and file references.
   - Final readiness assessment.

## Heuristics
- Prefer lower severity when uncertain (SUGGESTION > WARNING > CRITICAL).
- Every issue must include an actionable recommendation.
- Avoid vague advice.

## Graceful Degradation
- If only tasks exist: completeness only.
- If tasks + specs: completeness + correctness.
- If full artifacts: all dimensions.
- Always state skipped checks and why.
