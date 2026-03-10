Use this repo-local extension file for non-framework Ralph behavior.

Current local helper:
- For UI stories with role-sensitive access, run `./scripts/ralph/ralph-ui-role.sh` to suggest required role coverage before browser validation.

Future customizations:
- Add instructions for any new local helper scripts/capabilities here instead of editing `prompt.md`.
- Keep custom scripts under `scripts/ralph/` and reference them from this file so framework installs/updates do not disable project-specific behavior.

Reference:
- See `scripts/ralph/README-local.md` for local extension conventions and upgrade checklist.
