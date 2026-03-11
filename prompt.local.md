Use this repo-local extension file for non-framework Ralph behavior.

Use named block sections to inject content into matching markers in `prompt.md`.
Marker format in `prompt.md`: `<!-- RALPH:LOCAL:<NAME> -->`
Block format in this file:

```md
<!-- RALPH:LOCAL:<NAME> -->
...injected content...
<!-- /RALPH:LOCAL:<NAME> -->
```

<!-- RALPH:LOCAL:ROLE:HELPER -->
    - Determine role with `./scripts/ralph/ralph-ui-role.sh`.
    - Validate in authenticated required-role context.
    - Missing/wrong role is a blocker; fix before claiming acceptance.
<!-- /RALPH:LOCAL:ROLE:HELPER -->
