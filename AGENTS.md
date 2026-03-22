# Ralph Agent Instructions

## Overview

Ralph is an autonomous AI agent loop that runs Codex (`codex --yolo exec`) repeatedly until all PRD items are complete. Each iteration is a fresh Codex run with clean context.

## Commands

```bash
# Install skills globally for Codex
./install.sh --install-skills

# Install Ralph into a target project
./install.sh --project /path/to/your/project

# Generate and convert PRD into scripts/ralph/prd.json
./ralph-prd.sh

# Convert roadmap vision into sprint/epic backlogs
./ralph-roadmap.sh --vision "Roadmap from baseline to target state"

# Refine an existing roadmap source and reconcile downstream sprint backlogs
./ralph-roadmap.sh --refine --revision-note "Adjust roadmap after new findings"

# Optional OpenSpec -> Ralph conversion path (outside scripts/ralph runtime)
./scripts/openspec/openspec-skill.sh convert --change <change-name>

# Sprint helpers
./ralph-sprint.sh status
./ralph-sprint.sh create sprint-2
./ralph-sprint.sh use sprint-1

# Epic backlog sequencing helpers
./ralph-epic.sh list
./ralph-epic.sh start-next
./ralph-epic.sh add --title "My Epic" --effort 3 --depends-on EPIC-001 --prompt-context "Epic planning context"

# Prime prd.json for active/next eligible epic
./ralph-prime.sh

# Run Ralph loop (from your project that has prd.json)
./ralph.sh [max_iterations]

# Framework sanity smoke test (disposable install-repo E2E)
./scripts/smoke/e2e-sanity.sh --ci
./scripts/smoke/e2e-sanity.sh --with-loop
./scripts/smoke/e2e-sanity.sh --with-loop-standalone
./scripts/smoke/e2e-sanity.sh --with-loop-epic
./scripts/smoke/e2e-sanity.sh --with-loop --app-mode ui

# Archive / merge / cleanup lifecycle
./ralph-commit.sh
./ralph-sprint-commit.sh
./ralph-archive.sh
./ralph-cleanup.sh --force
```

## Key Files

- `ralph-prd.sh` - Interactive/non-interactive wrapper to create PRDs and convert to `prd.json`
- `ralph-roadmap.sh` - Roadmap planner that turns a broad future-state vision into sprint backlogs with effort-bounded epics
- `roadmap-source.md` - Durable roadmap source that can be revised later; roadmap/sprint reconciliation flows from it
- `ralph.sh` - The bash loop that spawns fresh Codex runs
- `ralph-prime.sh` - Auto-selects/uses active epic and primes `prd.json` for loop startup
- `ralph-sprint.sh` - Sprint container and active sprint management (`create/use/status/add-epics`)
- `ralph-epic.sh` - CLI to list/select/update epic order and status
- `ralph-archive.sh` - Archive run artifacts into sprint/standalone task archives and reset `prd.json`
- `ralph-commit.sh` - Validate completion, archive run, merge using mode-aware default target (epic -> sprint branch, standalone -> base branch), and sync epic status in epic mode
- `ralph-sprint-commit.sh` - Validate sprint completion, archive sprint-level state, and merge sprint branch into `master`/`main`
- `ralph-cleanup.sh` - Reset local Ralph artifacts without creating an archive
- `doctor.sh` - Sanity checks for a target repo
- `install.sh` - One-command installer into `scripts/ralph`
- `prompt.md` - Instructions given to each Codex run
- `prd.json.example` - Example PRD format
- `epics.json.example` - Example epic backlog template
- `prompts/*.md` - Optional reusable Codex command prompts installable to `~/.codex/prompts`
- `scripts/openspec/openspec-skill.sh` - Optional OpenSpec adapter that converts OpenSpec changes to `scripts/ralph/prd.json`

## Recommended Flow

1. Run `./doctor.sh`
2. If you changed local skills, run `./install.sh --install-skills` before PRD/prime runs
3. Create the roadmap/sprint plan via `./ralph-roadmap.sh --vision "..."`
4. Confirm active sprint via `./ralph-sprint.sh status` (or set one with `use/create`)
5. Select next epic via `./ralph-epic.sh start-next`
6. Prime loop input via `./ralph-prime.sh`
7. Run loop via `./ralph.sh [max_iterations]`
8. Run `./ralph-commit.sh` to archive + merge using mode-aware defaults (epic -> sprint branch, standalone -> base branch); epic runs auto-mark matching epic `done`
9. Run `./ralph-sprint-commit.sh` when sprint epics are all done/abandoned

Epic lifecycle helpers:
- `./ralph-epic.sh abandon EPIC-XXX "reason"` keeps epic for reference but excludes it from next/start-next
- `./ralph-epic.sh remove EPIC-XXX` permanently removes an already-abandoned epic

Flowchart assets/source were removed because they are no longer valid for this repository. A new repo-specific flowchart may be added in the future.

## Patterns

- Each iteration spawns a fresh Codex run with clean context
- Memory persists via git history, `progress.txt`, and `prd.json`
- Stories should be small enough to complete in one context window
- Always update AGENTS.md with discovered patterns for future iterations
- `ralph-epic.sh` requires an active sprint; use `ralph-sprint.sh use <sprint-name>` first if needed.
- Fresh installs already seed `sprint-1`; create additional sprints only when needed.
- `ralph-archive.sh` has no `--help`; invoking it performs an archive run immediately.
- `ralph-epic.sh add ...` provides a non-interactive epic creation path; use it for automation.
- Roadmap planning should keep sprint effort at or under capacity ceiling and use only sprint-safe epic effort scores (`1`, `2`, `3`, `5`); overflow work belongs in later sprints, not the current one.
- Keep explicit epic dependencies sprint-local; cross-sprint sequencing should be represented by sprint order, not cross-sprint `dependsOn` links.
- Roadmap refinement should be additive by default: preserve done/active work when possible, update open/future work directly, and prefer follow-up epics or new sprints over reopening closed sprints if churn would be high.
- Epics should track planning provenance: roadmap-managed work may be reconciled by `ralph-roadmap.sh`, while local ad hoc epics should be left alone unless dependency validation shows they are no longer valid.
- `ralph-commit.sh` and `ralph-sprint-commit.sh` delete merged source branches by default; pass `--keep` to retain them.
- `.active-prd` now includes explicit `baseBranch`; `ralph-commit.sh` should use it before fallback target inference.
- OpenSpec conversion is opt-in via `scripts/openspec/openspec-skill.sh` and is not invoked by `ralph.sh`; core Ralph loop behavior remains unchanged.
- Fresh-install epics should include `promptContext` so `ralph-prime.sh` can generate missing PRD markdown when starter `prdPaths` are not yet on disk.
- `ralph-sprint.sh status` should treat missing PRDs with `promptContext` as generatable warnings, and only fail for missing PRDs that cannot be generated.
- `ralph-sprint.sh status` now reports both `Active epic` and `Next epic` to avoid confusion when an epic is already active.
- Keep repo-specific Ralph behavior in `scripts/ralph/prompt.local.md` (and optional local helper scripts referenced there) so framework updates can refresh core files without disabling one-off project utilities.
- `ralph.sh` now supports marker-based local prompt injection: place `<!-- RALPH:LOCAL:<NAME> -->` in `prompt.md` and matching start/end blocks in `prompt.local.md`; empty local files are ignored and non-matching legacy local content falls back to append mode.

- Keep interactive wrappers minimal by default; provide `--detailed` mode for deeper prompts and CLI flags for non-interactive runs.
- Framework sanity smoke checks live in `scripts/smoke/e2e-sanity.sh`; local runs default to real Codex, CI runs with mock Codex for deterministic validation.
- Disposable smoke repos should configure a local git identity during setup so E2E runs do not depend on the developer having global `user.name` and `user.email` configured.
- `ralph-prd.sh --feature ... --no-questions` should stay non-interactive even when launched from a TTY; only open editor intake when the feature concept is missing or quick-question intake is still enabled.
- When the smoke harness runs under a TTY, explicitly redirect stdin from `/dev/null` for intentionally interactive wrappers (for example `ralph-sprint.sh create`) that are being used in automation-only setup steps.
- `ralph-verify.sh --targeted` should infer related tests for changed source files more broadly than exact basenames, and fall back to the full test suite when source files changed but no related targeted tests can be inferred.
- `ralph-prd.sh` now supports an opt-in compact planning path (`--compact` or `RALPH_PRD_COMPACT=1`) for tightly scoped work; keep it non-default so broader tasks still use the full planning prompt.
- Auto-compact PRD selection should be extremely conservative: only switch when the task is explicitly file-scoped, very small, and free of cross-cutting signals; otherwise keep the normal planning path.
- `ralph.sh` should skip the loop entirely when completion is already stable: all stories pass, completion evidence exists, and only transient Ralph artifacts remain dirty.
- Keep `prompt.md` terse because every Ralph iteration pays for it again; compress wording before adding new always-on instructions.
- For tiny file-scoped UI tasks, the loop prompt should prefer rebuilding local assets for browser verification over editing helper scripts like `scripts/browser-check.mjs`; keep the change inside the requested app/test files unless the PRD explicitly expands scope.
- For bounded-scope UI stories, keep source changes inside scope; verification of that scoped work is always allowed, but only to verify the scoped work.
- Keep loop-context reads tight: prefer `## Codebase Patterns`, the latest single progress entry, and the nearest relevant `AGENTS.md` before expanding outward.
- PRDs should decompose into 1-6 executable stories. Use task classes that fit that range (`micro` 1, `small` 2-3, `medium` 4-6); if honest decomposition needs more than 6, create a follow-up PRD instead of overstuffing one plan.
- Smoke telemetry should report both token totals and loop iteration counts/completion iteration so efficiency regressions can be traced to either planning cost or extra loop churn.
- Smoke runs should persist a lightweight local benchmark history under `scripts/smoke/.benchmarks/` so before/after efficiency changes can be compared without re-reading full logs.
- Keep a direct regression test for `ralph-verify.sh --targeted` selecting a related test for source-only changes; that behavior is important enough to test independently from the larger loop smoke.
- The tiny console standalone smoke case should assert that compact PRD mode actually activated, while UI smoke should assert that the normal planning path remained in use.
- For tiny file-scoped UI copy tasks that still require browser evidence, keep normal planning mode but explicitly nudge PRD generation toward a single story that combines the implementation change, matching regression update, and browser verification unless real sequencing is required.
