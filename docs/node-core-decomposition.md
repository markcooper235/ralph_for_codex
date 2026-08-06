# Node.js Core Decomposition Plan

## Goal

Move Ralph's stateful domain logic from Bash into a testable Node.js core while
keeping the existing shell commands and installed runtime layout compatible.
Bash remains responsible for process setup and operator-facing entry points;
Node owns validation, state transitions, selection, and durable JSON updates.

## Boundary

```text
shell CLI -> Node command API -> domain services -> repositories
                                  |               |
                                  |               +-- JSON/runtime files
                                  +-- ports -------- Git/Codex/SpecKit adapters
```

The core must not invoke `process.exit`, read global CLI arguments, change the
working directory, or mutate Git directly. Commands return structured results
and typed failures. Shell entry points translate those results into existing
text output and exit codes during migration.

## Proposed Modules

```text
scripts/ralph/core/
  cli/                 argument parsing and compatibility output
  domain/
    story.js           story states and transitions
    sprint.js          sprint states, capacity, and eligibility
    task.js            task/check validation
    verification.js    verification decisions and summaries
  application/
    select-next-story.js
    update-story-status.js
    prepare-story.js
    close-sprint.js
  repositories/
    backlog-repository.js
    story-repository.js
    runtime-repository.js
  ports/
    git.js
    harness.js
    specify.js
  adapters/
    git-process.js
    codex-process.js
    specify-process.js
  schema/
    stories.schema.json
    story.schema.json
```

## Implemented Migration Stages

The current main branch has completed and committed these compatibility-gated
stages:

- backlog selection and atomic status mutations (`next-id`, `set-status`, `abandon`, `start-next`);
- Git branch planning plus the process-backed Git adapter;
- Codex and Pi process execution behind the harness port;
- task dependency/completion rules and verification decisions;
- atomic story task/result/field writes;
- execution-plan, context, dependency-handoff, file-scope, and project-command services;
- atomic story runtime manifest writes and centralized story queries;
- repository shape validation for durable backlog/story inputs.

Every stage retains a shell fallback, has parity or adapter coverage, and is
validated by the full regression suite and `e2e-sanity.sh --ci --with-loop`.
The remaining shell responsibilities are process orchestration, acceptance
check execution, heartbeat timing, operator output, and compatibility fallback
paths. Those are intentionally kept at the boundary until their process and
runtime contracts are separately characterized.

Start with plain ESM JavaScript, JSDoc types, Node's built-in test runner, and
no runtime dependencies. Introduce TypeScript only if schema-derived types or
the application layer becomes difficult to maintain with JSDoc.

## Migration Sequence

1. Freeze behavior with command-level characterization fixtures, including
   output and exit-code contracts.
2. Implement schemas and read-only repositories. Compare Node parsing and
   validation against the Bash/JQ implementation on the same fixture corpus.
3. Move pure selection and transition rules (`next-id`, valid transitions,
   dependency eligibility) into domain modules.
4. Move JSON mutations behind repositories using same-directory temporary
   files, `fsync`, and atomic rename. Keep Bash as the public dispatcher.
5. Add Git, harness, and SpecKit ports. Test application services with fake
   adapters before connecting process-backed adapters.
6. Migrate preparation and execution orchestration one use case at a time.
7. Replace compatibility output only in a separately versioned CLI change.
8. Remove superseded Bash modules after parity tests pass in installed-repo,
   upgrade, smoke, and framework-selftest scenarios.

## First Vertical Slice

The initial `next-id` slice was implemented first. It is read-only, deterministic, and exercises the
important repository/domain split:

- repository loads and validates `stories.json`;
- domain service selects the first eligible story;
- shell wrapper preserves current output and missing-dependency behavior;
- fixture tests run Bash and Node implementations against identical inputs.

It was followed by `set-status`, `abandon`, and `start-next`, which established
atomic writes, transition validation, and the Git port boundary. Subsequent
execution and runtime services now follow the same shell-compatible migration
pattern.

## Compatibility Gates

- Existing command names, flags, stdout, stderr, and exit codes remain stable.
- Installed copies do not depend on this framework repository or global npm
  packages.
- Node mutations never leave partially written JSON.
- Runtime artifacts remain transient; planning artifacts remain durable.
- Every migrated command has parity fixtures plus an end-to-end smoke test.
- Rollback is possible per command by switching its shell dispatcher back to
  the Bash implementation.
