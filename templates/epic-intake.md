# Ralph Epic Intake

Fill in the `BEGIN INPUT` section, save, and close your editor.

Context:
- Use existing epics snapshot at the bottom of this file while filling dependencies.

<!-- BEGIN INPUT -->
EPIC_ID: {{DEFAULT_EPIC_ID}}
TITLE:
PRIORITY: {{DEFAULT_PRIORITY}}
EFFORT: 3
STATUS: planned
DEPENDS_ON:
PRD_PATHS: scripts/ralph/tasks/{{SPRINT_NAME}}/prd-epic-{{EPIC_NUM_LOWER}}-short-title.md
GOAL:
OPEN_QUESTION: None currently.
PROMPT_CONTEXT:
Provide conversation/prompt context for PRD story generation.
Include:
- rules/invariants that must not drift
- the intended first slice or first migration order
- realistic supporting file families that may need to move
- verification proof expectations
- literal proof phrases when known, for example: Typecheck passes, Lint passes, Unit tests pass, Tests pass, Verify in browser
- explicit out-of-scope boundaries
- any neighboring epics this one must not overlap with
- any checker-sensitive structural requirements that must be present in the PRD on first generation
<!-- END INPUT -->
