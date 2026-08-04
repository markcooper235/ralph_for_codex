#!/bin/bash
# Deterministic mock Codex for smoke tests. Besides satisfying doctor checks,
# it applies the three fixture edits used by e2e-sanity.sh --with-loop.

set -euo pipefail

case " $* " in
  *" --help "*) exit 0 ;;
esac

prompt="$(cat)"
workspace="$PWD"
previous_arg=""
for arg in "$@"; do
  if [ "$previous_arg" = "-C" ]; then
    workspace="$arg"
    break
  fi
  previous_arg="$arg"
done
cd "$workspace"

story_file="$(printf '%s\n' "$prompt" | awk '/^Primary durable story file:$/ { getline; print; exit }')"
story_title=""
if [ -n "$story_file" ] && [ -f "$story_file" ]; then
  story_title="$(jq -r '.title // empty' "$story_file")"
fi

if [ "$story_title" = 'Update greeting to Hello Sprint Ralph' ]; then
  perl -pi -e 's/Hello World/Hello Sprint Ralph/g' src/index.ts tests/hello.test.mjs
fi

if [ "$story_title" = 'Add app identifier output' ]; then
  if ! grep -q 'sprint-smoke' src/index.ts; then
    printf '%s\n' 'console.log("App: sprint-smoke");' >> src/index.ts
  fi
  if ! grep -q 'sprint-smoke' tests/hello.test.mjs; then
    printf '%s\n' 'assert.match(source, /sprint-smoke/, "Expected app identifier in src/index.ts");' >> tests/hello.test.mjs
  fi
fi

if [ "$story_title" = 'Add status message output' ]; then
  if ! grep -q 'Status: ready' src/index.ts; then
    printf '%s\n' 'console.log("Status: ready");' >> src/index.ts
  fi
  if ! grep -q 'Status: ready' tests/hello.test.mjs; then
    printf '%s\n' 'assert.match(source, /Status: ready/, "Expected status message in src/index.ts");' >> tests/hello.test.mjs
  fi
fi

exit 0
