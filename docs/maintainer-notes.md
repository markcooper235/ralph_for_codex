# Ralph Maintainer Notes

This file holds framework-maintainer details that are intentionally too specific for `AGENTS.md`.

Use `AGENTS.md` for the broad operating model. Use this file when you need deeper policy, edge-case behavior, or the rationale behind current framework decisions.

## Table of Contents

- [Documentation Policy](#documentation-policy)
- [Sprint And Roadmap Policy](#sprint-and-roadmap-policy)
- [SpecKit Integration Policy](#speckit-integration-policy)
- [Story Health Policy](#story-health-policy)
- [Execution And Task Policy](#execution-and-task-policy)
- [Fallow Gate Policy](#fallow-gate-policy)
- [Completion And Branch Policy](#completion-and-branch-policy)
- [Prompt And Intake Policy](#prompt-and-intake-policy)
- [Archive And Merge Policy](#archive-and-merge-policy)
- [Story Sizing Policy](#story-sizing-policy)
- [Smoke Harness Notes](#smoke-harness-notes)

---

## Documentation Policy

- Repo docs should describe the framework in terms of the simple operator flow: install, plan, prepare, run, commit.
- Keep advanced helpers behind the main path instead of leading with internals.
- README-level documentation should emphasize the current capabilities: roadmap planning, SpecKit preparation, story-task execution model, binary acceptance checks, fallow gate, and sprint closeout.
- The story-task architecture is the canonical model; legacy PRD/epic terminology should not appear in new operator-facing documentation.

---

## Sprint And Roadmap Policy

- `ralph-story.sh` requires an active sprint for commands that resolve from `.active-sprint`; use `ralph-sprint.sh use <sprint-name>` first if needed.
- `ralph-story.sh add ...` provides a non-interactive story creation path and is the preferred automation path.
- Roadmap planning should keep sprint effort at or under the capacity ceiling and use only sprint-safe story effort scores: `1`, `2`, `3`, `5`.
- Overflow work belongs in later sprints, not the current one.
- Keep explicit story dependencies sprint-local; cross-sprint sequencing should be represented by sprint order.
- Roadmap refinement should be additive by default: preserve done or active work, update open or future work directly, and prefer follow-up stories or new sprints over reopening closed sprints.
- Stories should track planning provenance: roadmap-managed work may be reconciled by `ralph-roadmap.sh`, while local ad hoc stories should be left alone unless dependency validation fails.
- `ralph-sprint.sh status` should report both `Active story` and `Next story` to avoid confusion when a story is already active.
- `ralph-sprint.sh next` should ignore sprints when their remaining stories are all `blocked`.

---

## SpecKit Integration Policy

- SpecKit analysis runs three sequential phases via `ralph-story.sh specify <ID>`: specify → plan → tasks.
- Output artifacts are written to `<story-dir>/.specify/{spec.md, plan.md, tasks.md}`.
- `.specify/` artifacts are durable and should be committed alongside `story.json`.
- `ralph-story.sh generate <ID>` detects `.specify/` artifacts and uses the `story-specify` skill when present; it falls back to the `story-generate` skill when artifacts are absent.
- `ralph-story.sh specify-all` and `generate-all` support `--jobs N` for parallel execution.
- `ralph-story.sh prepare-all` = specify-all + generate-all + health + promote to ready. It is the recommended single-command story preparation path.
- SpecKit requires the `specify` CLI to be installed. `doctor.sh` checks for it and fails if missing. Install via `--install-speckit` or `uvx --from git+https://github.com/github/spec-kit.git specify init <PROJECT>`.
- When `specify` is absent and cannot be found via `npx`, `ralph-story.sh specify` fails with a clear message — there is no silent fallback for SpecKit phases.

---

## Story Health Policy

- `ralph-story.sh health [ID]` validates active (non-done, non-abandoned) stories; `health-all` covers all stories.
- Health checks cover: story.json existence, task count > 0, acceptance check count per task, context completeness, task `depends_on` integrity (no dead references, no self-referencing), duplicate checks within a task, tasks with identical check sets, and check syntax/command reachability.
- SpecKit artifact completeness is also validated when a `.specify/` directory exists for the story.
- `prepare-all` only promotes a story to `ready` when health passes and the story has a valid `story.json` with at least one task.
- A story with health warnings should not be executed by `ralph.sh` — fix issues first, then re-run `ralph-story.sh health`.

---

## Execution And Task Policy

- `ralph.sh` only operates when on the sprint branch (`ralph/sprint/<sprint-name>`); it fails with a clear message when the working tree is dirty or the branch is wrong.
- `ralph.sh` warns before the loop when stories have no `story.json`, prompting `prepare-all` first.
- `ralph-task.sh` locks execution via `.workflow-lock`; the lock is shared with `ralph.sh` via `RALPH_LOCK_HELD`.
- Each task's `checks[]` are evaluated by running each shell expression from the workspace root. All checks must exit 0 for the task to pass.
- Task retry resets the Codex session and re-evaluates checks from scratch. `--max-retries` controls the ceiling.
- Task `done_note` is written on success and passed as context to downstream dependent tasks and stories.
- The story `done_note` summarizes all passing tasks and the total git diff stat. It is used as context when dependent stories are prepared via `ralph-story.sh specify`.

---

## Fallow Gate Policy

- `ralph-fallow.sh` runs automatically after all task checks pass, before the story branch is merged.
- It uses `fallow audit` (fallow.tools) for JS/TS projects. For projects without `package.json`/`tsconfig.json`, it falls back to a built-in grep-based heuristic.
- Gate flow: audit → if issues: `fallow fix --yes` + Codex session → re-audit → pass/fail.
- `--dry-run` reports issues without auto-fixing or failing the gate.
- `--no-autofix` reports and fails without attempting auto-fix.
- `--skip-fallow` in `ralph.sh` and `ralph-task.sh` bypasses the gate entirely (for debugging only).
- The fallow gate operates on files changed vs `main`; it matches the story's contribution exactly.

---

## Completion And Branch Policy

- `ralph-task.sh` marks a story `done` when all task `passes` fields are `true`.
- On story completion, `ralph-task.sh` automatically merges the story branch into the sprint branch using `--no-ff` and deletes the story branch.
- If the merge has conflicts, the story branch is left intact for manual resolution.
- Sprint closeout via `ralph-sprint-commit.sh` requires all stories to be `done` or `abandoned`; it will not proceed with `active`, `planned`, or `ready` stories remaining.
- `ralph-sprint-commit.sh` archives sprint metadata to `tasks/archive/sprints/` before merging.
- Sprint branches are deleted after merge by default; pass `--keep` to retain.
- `ralph-sprint-commit.sh` requires `ralph-sprint-test.sh` to exist and pass before merging. This file is project-specific — copy from `ralph-sprint-test.sh.example`.

---

## Prompt And Intake Policy

- Keep repo-specific Ralph behavior in `scripts/ralph/prompt.local.md` and optional local helper scripts referenced there so framework updates can refresh core files safely.
- `ralph.sh` supports marker-based local prompt injection: place `<!-- RALPH:LOCAL:<NAME> -->` in `prompt.md` and matching start/end blocks in `prompt.local.md`.
- Empty local prompt files are ignored; non-matching legacy local content falls back to append mode.
- Keep interactive wrappers minimal by default; provide CLI flags for non-interactive runs.
- Keep `prompt.md` terse because every Ralph iteration pays for it.

---

## Archive And Merge Policy

- Sprint-level archive is written to `tasks/archive/sprints/<sprint-name>/` by `ralph-sprint-commit.sh`.
- `.active-prd` includes explicit `baseBranch`; scripts should use it before fallback target inference when it exists.
- Transient per-story files (`.task-log-*.txt`, `.fallow-report.json`, `.fallow-autofix.txt`) are cleaned up automatically after a successful story merge.

---

## Story Sizing Policy

- Sprint backlogs should decompose into independently shippable stories.
- Use story effort scores that fit sprint capacity: `micro` 1, `small` 2-3, `medium` 4-5.
- Each story should have 2-5 tasks in `story.json`. If honest decomposition needs more, create a follow-up story.
- Tasks must be completable in a single focused Codex session.

---

## Smoke Harness Notes

- Framework sanity smoke checks live in `scripts/smoke/e2e-sanity.sh`; local runs default to real Codex and CI runs with mock Codex for deterministic validation.
- Disposable smoke repos should configure a local git identity during setup so E2E runs do not depend on the developer having global `user.name` and `user.email` configured.
- When the smoke harness runs under a TTY, explicitly redirect stdin from `/dev/null` for intentionally interactive wrappers when they are used in automation-only setup steps.
- Smoke telemetry should report both token totals and loop iteration counts so efficiency regressions can be traced to planning cost or extra loop churn.
- Smoke runs should persist a lightweight local benchmark history under `scripts/smoke/.benchmarks/` for before/after efficiency comparison.
- Smoke retry handling should clear only provably stale workflow locks in disposable smoke repos; core Ralph lock semantics in `ralph.sh` and `ralph-task.sh` are not weakened.
- Worst-case UI smoke validates runtime UI behavior instead of overfitting to exact implementation spelling.
