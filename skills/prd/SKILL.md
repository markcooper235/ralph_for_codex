---
name: prd
description: "Generate a Product Requirements Document (PRD) for a new feature. Use when planning a feature, starting a new project, or when asked to create a PRD. Triggers on: create a prd, write prd for, plan this feature, requirements for, spec out."
---

# PRD Generator

Create implementation-ready PRDs. Do not implement code in this skill.

## Non-Negotiables

- Do not implement code; only produce PRD output.
- Ask 3-5 clarifying questions only when needed.
- Keep acceptance criteria specific and verifiable.
- Add browser verification for UI-impacting stories.
- Save only to `tasks/prd-[feature-name].md` (kebab-case).

## The Job

1. Receive the feature request.
2. Ask 3-5 clarifying questions only when needed.
3. Generate a structured PRD from answers.
4. Save to `tasks/prd-[feature-name].md` (kebab-case).

## Clarifying Questions

Ask only for ambiguous, high-impact gaps:

- Problem/goal
- Core functionality
- Scope boundaries (explicit non-goals)
- Success criteria

Use lettered options so users can reply quickly (`1A, 2C, 3B`).

```text
1. What is the primary goal?
   A. Improve onboarding
   B. Increase retention
   C. Reduce support load
   D. Other: [specify]
```

## PRD Structure

Include these sections:

1. Introduction/Overview
2. Goals (specific, measurable bullets)
3. User Stories
4. Functional Requirements (`FR-1`, `FR-2`, ...)
5. Non-Goals (Out of Scope)
6. Design Considerations (optional)
7. Technical Considerations (optional)
8. Success Metrics
9. Open Questions

### User Story Format

Each story must be small enough for one focused implementation session.

```markdown
### US-001: [Title]
**Description:** As a [user], I want [feature] so that [benefit].

**Acceptance Criteria:**
- [ ] Verifiable criterion
- [ ] Another verifiable criterion
- [ ] Typecheck/lint passes
- [ ] **[UI stories only]** Verify in browser using dev-browser skill
```

Rules:

- Criteria must be testable and specific (no "works correctly").
- UI-impacting stories must include browser verification.

## Writing Style

Assume a junior developer or AI agent will implement it:

- Be explicit and unambiguous.
- Minimize jargon or define it.
- Use numbered requirements for traceability.
- Add concrete examples only when they clarify behavior.

## Output

- Format: Markdown (`.md`)
- Location: `tasks/`
- Filename: `prd-[feature-name].md`
