# Ralph Maintainer Notes

This file holds framework-maintainer details that are intentionally too specific for `AGENTS.md`.

Use `AGENTS.md` for the broad operating model. Use this file when you need deeper policy, edge-case behavior, or the rationale behind current framework decisions.

## Documentation Policy

- Repo docs should describe the framework in terms of the simple operator flow: install, plan, run, commit.
- Keep advanced helpers behind the main path instead of leading with internals.
- README-level documentation should emphasize the current capabilities that materially changed framework behavior: roadmap planning, auto-priming, targeted-to-full verification flow, scoped-work enforcement, marker-based local prompt injection, and archive/merge lifecycle defaults.

## Sprint And Roadmap Policy

- `ralph-epic.sh` requires an active sprint; use `ralph-sprint.sh use <sprint-name>` first if needed.
- `ralph-epic.sh add ...` provides a non-interactive epic creation path and is the preferred automation path.
- Roadmap planning should keep sprint effort at or under the capacity ceiling and use only sprint-safe epic effort scores: `1`, `2`, `3`, `5`.
- Overflow work belongs in later sprints, not the current one.
- Keep explicit epic dependencies sprint-local; cross-sprint sequencing should be represented by sprint order, not cross-sprint `dependsOn` links.
- Roadmap refinement should be additive by default: preserve done or active work when possible, update open or future work directly, and prefer follow-up epics or new sprints over reopening closed sprints if churn would be high.
- Epics should track planning provenance: roadmap-managed work may be reconciled by `ralph-roadmap.sh`, while local ad hoc epics should be left alone unless dependency validation shows they are no longer valid.
- Fresh-install epics should include `promptContext` so `ralph-prime.sh` can generate missing PRD markdown when starter `prdPaths` are not yet on disk.
- `ralph-sprint.sh status` should treat missing PRDs with `promptContext` as generatable warnings, and only fail for missing PRDs that cannot be generated.
- `ralph-sprint.sh status` should report both `Active epic` and `Next epic` to avoid confusion when an epic is already active.

## Prompt And Intake Policy

- Keep repo-specific Ralph behavior in `scripts/ralph/prompt.local.md` and optional local helper scripts referenced there so framework updates can refresh core files safely.
- `ralph.sh` supports marker-based local prompt injection: place `<!-- RALPH:LOCAL:<NAME> -->` in `prompt.md` and matching start/end blocks in `prompt.local.md`.
- Empty local prompt files are ignored; non-matching legacy local content falls back to append mode.
- Keep interactive wrappers minimal by default; provide `--detailed` mode for deeper prompts and CLI flags for non-interactive runs.
- `ralph-prd.sh --feature ... --no-questions` should stay non-interactive even when launched from a TTY; only open editor intake when the feature concept is missing or quick-question intake is still enabled.
- `ralph-prd.sh` supports an opt-in compact planning path via `--compact` or `RALPH_PRD_COMPACT=1` for tightly scoped work, but it should remain non-default.
- Auto-compact PRD selection should be extremely conservative: only switch when the task is explicitly file-scoped, very small, and free of cross-cutting signals.
- For tiny file-scoped UI copy tasks that still require browser evidence, keep normal planning mode but nudge PRD generation toward a single story that combines the implementation change, matching regression update, and browser verification unless real sequencing is required.
- Keep `prompt.md` terse because every Ralph iteration pays for it again.
- Keep loop-context reads tight: prefer `## Codebase Patterns`, the latest single progress entry, and the nearest relevant `AGENTS.md` before expanding outward.

## Verification And Scope Policy

- `ralph-verify.sh --targeted` should infer related tests for changed source files more broadly than exact basenames.
- If source files changed but no related targeted tests can be inferred, targeted verification should fall back to the full test suite.
- For tiny file-scoped UI tasks, the loop prompt should prefer rebuilding local assets for browser verification over editing helper scripts like `scripts/browser-check.mjs`.
- Keep source changes inside the requested files unless the PRD explicitly expands scope.
- Allow verification-only expansion only to verify that scoped work.
- `ralph.sh` performs a light explicit-scope validator: when the PRD or source text clearly says a change is limited to named files, iteration commits may expand only into verification or test files outside that source scope.
- `prd.json` may include optional top-level and per-story `scopePaths`; `ralph.sh` should prefer that structured metadata over text inference when present.
- Helper scripts, build scripts, configs, fixtures, and package metadata should stay out of `scopePaths` unless the task explicitly requires changing them.
- Explicit scope enforcement should validate both committed changes and current worktree changes; otherwise out-of-scope edits that were never committed can silently delay loop completion.

## Completion And Handoff Policy

- `ralph.sh` should skip the loop entirely when completion is already stable: all stories pass, completion evidence exists, and only transient Ralph artifacts remain dirty.
- Ralph should finalize completion from wrapper-observable facts, not extra model bookkeeping.
- Once all stories pass, full verification is recorded, and only transient files remain dirty, `ralph.sh` should write completion state itself and stop immediately.
- Ralph loop completion is handoff-driven: `.iteration-handoff*.json` is the canonical per-iteration state, `.iteration-log*.txt` remains the full transcript artifact, and completion detection should read the structured handoff rather than a raw last-message sentinel.
- Ralph now writes `.completion-state.json` itself when completion is stable; treat that file as the canonical loop-complete marker and keep `progress.txt` human-readable rather than machine-critical.
- Handoff validation should prefer Ralph state over exact output phrasing: completion can be proven by passing stories plus a recognized progress completion note plus full verification evidence, even when the emitted handoff schema is malformed or overly verbose.
- `progress.txt` completion markers are not fully normalized in real runs yet; Ralph should recognize both timestamped completion headings and `## Completion Note` blocks when deciding whether loop completion is stable.
- When Codex itself exits non-zero, preserve the transcript but record a blocked fallback handoff with the exit status so the failure is explicit instead of looking like a generic missing-handoff iteration.
- When extracting a structured handoff from the transcript, use the last `<ralph_handoff>` block, not the first one, because the prompt itself includes an example wrapper earlier in the transcript.

## Archive And Merge Policy

- `ralph-commit.sh` and `ralph-sprint-commit.sh` delete merged source branches by default; pass `--keep` to retain them.
- `.active-prd` includes explicit `baseBranch`; `ralph-commit.sh` should use it before fallback target inference.
- OpenSpec conversion is opt-in via `scripts/openspec/openspec-skill.sh` and is not invoked by `ralph.sh`; core Ralph loop behavior remains unchanged.

## Story Sizing Policy

- PRDs should decompose into 1-6 executable stories.
- Use task classes that fit that range: `micro` 1, `small` 2-3, `medium` 4-6.
- If honest decomposition needs more than 6 stories, create a follow-up PRD instead of overstuffing one plan.

## Smoke Harness Notes

- Framework sanity smoke checks live in `scripts/smoke/e2e-sanity.sh`; local runs default to real Codex and CI runs with mock Codex for deterministic validation.
- Disposable smoke repos should configure a local git identity during setup so E2E runs do not depend on the developer having global `user.name` and `user.email` configured.
- When the smoke harness runs under a TTY, explicitly redirect stdin from `/dev/null` for intentionally interactive wrappers such as `ralph-sprint.sh create` when they are being used in automation-only setup steps.
- Smoke telemetry should report both token totals and loop iteration counts or completion iteration so efficiency regressions can be traced to either planning cost or extra loop churn.
- Smoke runs should persist a lightweight local benchmark history under `scripts/smoke/.benchmarks/` so before or after efficiency changes can be compared without re-reading full logs.
- Keep a direct regression test for `ralph-verify.sh --targeted` selecting a related test for source-only changes.
- The tiny console standalone smoke case should assert that compact PRD mode actually activated, while UI smoke should assert that the normal planning path remained in use.
- Worst-case UI smoke validates runtime UI behavior instead of overfitting to exact implementation spelling.
- Smoke retry handling should clear only provably stale workflow locks in disposable smoke repos; core Ralph lock semantics remain unchanged.
