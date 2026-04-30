Use this repo-local extension file for non-framework Ralph behavior.

Use named block sections to inject content into matching markers in `prompt.md`.
Marker format in `prompt.md`: `<!-- RALPH:LOCAL:<NAME> -->`
Block format in this file:

```md
<!-- RALPH:LOCAL:<NAME> -->
...injected content...
<!-- /RALPH:LOCAL:<NAME> -->
```

---

## Project Commands (customize for this project)

Uncomment and fill in the commands for your project. These are referenced by story task
`checks[]` and by the story-generate skill when designing task containers.

<!--
Project build system: npm / yarn / pnpm / make / cargo / go / other

Typecheck:   npm run typecheck
Lint:        npm run lint
Test:        npm test
Build:       npm run build
Test scoped: npm test -- --testPathPattern=<pattern>

Browser check (UI projects only):
             npm run browser:check -- '<headline>' '<status>' '<cta>'
-->
