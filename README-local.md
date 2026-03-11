# Ralph Local Extensions

This file documents project-specific Ralph behavior that is intentionally outside the shared framework.

## Purpose

Use local extensions when this repo needs capabilities that should not be pushed into the global Ralph install framework.

## Where to Put Customizations

- Prompt-level behavior: `scripts/ralph/prompt.local.md`
- Helper scripts: `scripts/ralph/*.sh` (for example `scripts/ralph/ralph-ui-role.sh`)
- Repo policy hint: `AGENTS.md` (short reminder only)
- Starter template: `scripts/ralph/new-local-extension.sh.example`

## Update-Safe Rules

- Do not edit `scripts/ralph/prompt.md` for repo-only behavior.
- Put repo-only instructions in `scripts/ralph/prompt.local.md`.
- Reference all local helper scripts from `prompt.local.md` so they remain discoverable.
- Keep helper scripts idempotent and safe to run repeatedly.
- Prefer additive changes; avoid modifying core framework scripts unless needed.
- `prompt.local.md` is ignored when empty/whitespace-only.
- Marker-mode injection:
  - Add marker placeholders in `prompt.md`, for example: `<!-- RALPH:LOCAL:ROLE:HELPER -->`
  - Add matching blocks in `prompt.local.md`:
    - `<!-- RALPH:LOCAL:ROLE:HELPER -->`
    - `...content...`
    - `<!-- /RALPH:LOCAL:ROLE:HELPER -->`
  - `ralph.sh` injects matching block content at marker locations.
- Backward compatibility fallback:
  - If no matching marker blocks are found, non-empty `prompt.local.md` is appended as `## Local Prompt Extensions`.

## Existing Local Extension

- `scripts/ralph/ralph-ui-role.sh`
  - Example local helper for role-sensitive UI validation.
  - Keep it in the target project repo if needed; do not treat it as a core framework file.

## When Adding a New Local Capability

1. Add/update script under `scripts/ralph/`.
   Use `scripts/ralph/new-local-extension.sh.example` as the starting point.
2. Add usage instructions to `scripts/ralph/prompt.local.md`.
3. Add one-line note in `AGENTS.md` if policy/process changed.
4. Run `./scripts/ralph/doctor.sh` and a small Ralph iteration sanity check.

## Upgrade Checklist (Framework Reinstall)

1. Re-run framework installer.
2. Confirm `scripts/ralph/prompt.local.md` still exists and marker blocks still inject (or append fallback still works).
3. Confirm local helper scripts still exist and are executable.
4. Re-run one targeted Ralph workflow to validate behavior.
