#!/bin/bash
# Ralph doctor - sanity checks for running Ralph in a project

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CODEX_BIN="${CODEX_BIN:-codex}"
RALPH_HARNESS="${RALPH_HARNESS:-codex}"

load_ralph_env() {
  local env_file="$1"
  [ -f "$env_file" ] || return 1
  set -a
  # shellcheck source=/dev/null
  . "$env_file"
  set +a
  return 0
}

if ! load_ralph_env "${SCRIPT_DIR}/.ralph-env"; then
  load_ralph_env "${HOME}/.ralph-env" || true
fi
source "$SCRIPT_DIR/lib/provider-env.sh"
ralph_normalize_provider_env

source "$SCRIPT_DIR/lib/sprint-layout.sh"
source "$SCRIPT_DIR/lib/specify.sh"
source "$SCRIPT_DIR/lib/harness-capabilities.sh"
source "$SCRIPT_DIR/lib/harness-exec.sh"

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/doctor.sh

Sanity checks for running Ralph in the current project.

Options:
  -h, --help  Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

ROADMAP_FILE="$SCRIPT_DIR/roadmap.json"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
SPRINTS_DIR="$SCRIPT_DIR/sprints"
LEGACY_TRANSIENT_FILES=(
  "$SCRIPT_DIR/prd.json"
  "$SCRIPT_DIR/progress.txt"
  "$SCRIPT_DIR/.completion-state.json"
  "$SCRIPT_DIR/.active-prd"
)

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

validate_framework_json() {
  local json_file="$1"
  [ -f "$json_file" ] || fail "Missing framework file: $json_file"
  jq empty "$json_file" >/dev/null 2>&1 || fail "Invalid JSON: $json_file"
}

render_profile_preview() {
  local story_meta_json="$1"
  [ -n "$story_meta_json" ] || return 0
  (
    unset RALPH_MODEL RALPH_AGENT RALPH_COMPOSITE_PROFILE RALPH_COMPOSITE_PROFILE_JSON \
      RALPH_COMPOSITE_SHAPE RALPH_COMPOSITE_REQUIRED_EXTENSIONS_JSON \
      RALPH_COMPOSITE_SUBAGENT_ROLES_JSON RALPH_COMPOSITE_STEPS_JSON \
      RALPH_MODEL_SELECTION_SOURCE RALPH_AGENT_SELECTION_SOURCE RALPH_PIAGENT_ROLE \
      RALPH_HARNESS_OVERRIDE RALPH_HARNESS_SELECTION_SOURCE RALPH_EXECUTION_TIER
    local effective_agent complexity_pair complexity_score complexity_tier explicit_story_agent
    explicit_story_agent="$(printf '%s' "$story_meta_json" | jq -r '.agent // empty' 2>/dev/null || true)"
    effective_agent="$(_get_effective_agent "$story_meta_json")"
    complexity_pair="$(_story_complexity_score "$story_meta_json")"
    complexity_score="${complexity_pair%%:*}"
    complexity_tier="${complexity_pair#*:}"
    STORY_COMPLEXITY_SCORE="$complexity_score"
    STORY_COMPLEXITY_TIER="$complexity_tier"
    export STORY_COMPLEXITY_SCORE STORY_COMPLEXITY_TIER
    if [ -n "$explicit_story_agent" ]; then
      RALPH_AGENT_SELECTION_SOURCE="explicit"
    elif [ "$effective_agent" != "default" ]; then
      RALPH_AGENT_SELECTION_SOURCE="inferred"
    else
      RALPH_AGENT_SELECTION_SOURCE="default"
    fi
    export RALPH_AGENT_SELECTION_SOURCE
    _apply_agent_profile "$effective_agent"
    printf '%s\n' "$(get_execution_profile_json "$effective_agent")"
  )
}

print_resolution_preview() {
  local story_meta_json=""
  if [ -f "$ACTIVE_SPRINT_FILE" ]; then
    local active_sprint stories_file active_story_id
    active_sprint="$(awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE" || true)"
    stories_file="$(sprint_stories_file "$active_sprint")"
    if [ -f "$stories_file" ]; then
      active_story_id="$(jq -r '.activeStoryId // empty' "$stories_file" 2>/dev/null || true)"
      if [ -n "$active_story_id" ]; then
        story_meta_json="$(jq -c --arg id "$active_story_id" '.stories[] | select(.id == $id)' "$stories_file" 2>/dev/null || true)"
      fi
      if [ -z "$story_meta_json" ]; then
        story_meta_json="$(jq -c '.stories[0] // empty' "$stories_file" 2>/dev/null || true)"
      fi
    fi
  fi

  if [ -z "$story_meta_json" ] && [ -f "$ROADMAP_FILE" ]; then
    story_meta_json="$(jq -c '.sprints[0].stories[0] // empty' "$ROADMAP_FILE" 2>/dev/null || true)"
  fi

  [ -n "$story_meta_json" ] || return 0
  local preview
  preview="$(render_profile_preview "$story_meta_json")"
  [ -n "$preview" ] || return 0
  echo "Profile preview: $(printf '%s' "$preview" | jq -c '.')"
}

echo "Ralph doctor"
echo "ralph dir: $SCRIPT_DIR"
echo "harness: $RALPH_HARNESS"
echo "runtime home: $RALPH_RUNTIME_HOME_DIR"
case "$RALPH_RUNTIME_HOME_DIR" in
  "$SCRIPT_DIR"/runtime/home|"$SCRIPT_DIR"/runtime/home/*)
    echo "OK: runtime home is project-local"
    ;;
  *)
    echo "WARN: runtime home is not project-local"
    ;;
esac
if _composites_enabled; then
  echo "composites: enabled"
else
  echo "composites: disabled"
fi

require_cmd git
require_cmd jq

for provider_harness in codex piagent; do
  if provider_route="$(ralph_provider_route_for_harness "$provider_harness")"; then
    echo "OK: $provider_harness credentials configured via $provider_route environment"
  else
    echo "WARN: $provider_harness has no API key configured in .ralph-env"
  fi
done

validate_framework_json "$SCRIPT_DIR/lib/agent-profiles.json"
validate_framework_json "$SCRIPT_DIR/lib/composite-profiles.json"
validate_framework_json "$SCRIPT_DIR/lib/label-to-agent-mapping.json"
validate_framework_json "$SCRIPT_DIR/lib/harness-capabilities.json"

  case "$RALPH_HARNESS" in
  codex)
    require_cmd "$CODEX_BIN"
    ;;
  piagent)
    require_cmd pi
    ;;
  *)
    fail "Unknown harness: $RALPH_HARNESS"
    ;;
esac

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "Not inside a git repository. Run this from within your project repo."
fi

SPRINT_TEST_FILE="$SCRIPT_DIR/ralph-sprint-test.sh"
if [ ! -f "$SPRINT_TEST_FILE" ]; then
  echo "INFO: optional ralph-sprint-test.sh not found."
  echo "      It is required only for ralph-sprint-commit.sh --full-regression."
  echo "      To enable that gate, copy $SCRIPT_DIR/ralph-sprint-test.sh.example and customize it."
fi

# SpecKit artifacts should be committed with the sprint, not gitignored
SAMPLE_SPECIFY_PATH="$SCRIPT_DIR/backlog/sprint-1/stories/S-001/.specify/spec.md"
if git check-ignore -q "$SAMPLE_SPECIFY_PATH" 2>/dev/null; then
  echo "WARN: SpecKit .specify/ artifacts appear to be gitignored — spec files will not be committed."
  echo "      Check .gitignore for patterns matching '.specify' and remove them."
else
  echo "OK: .specify/ artifacts are not gitignored"
fi

echo "OK: Ralph uses story-local SpecKit artifacts under each story's .specify/ directory"
echo "    Project-level 'specify init' is optional and not required for Ralph workflows."

if specify_bin="$(find_specify_bin)"; then
  specify_source="$(describe_specify_bin "$specify_bin")"
  case "$specify_source" in
    "repo-local wrapper")
      echo "OK: specify available via the repo-local wrapper"
      echo "    Wrapper resolution prefers uv/uvx and uses global specify only as a last resort."
      ;;
    "uvx fallback")
      echo "WARN: specify is available via uv/uvx fallback"
      echo "      This works, but it is not a durable repo-local wrapper install and may depend on network/tooling at runtime."
      echo "      For a self-contained repo setup, ensure uv is available, then re-run install.sh."
      ;;
    *)
      echo "OK: specify CLI found via global install"
      ;;
  esac
else
  fail "'specify' CLI not found — required for story specification.
  Install the CLI: uv tool install git+https://github.com/github/spec-kit.git
  Or use:          npx --yes specify version
  Or:      bash install.sh --install-speckit"
fi

if [ ! -f "$ROADMAP_FILE" ]; then
  echo "WARN: Missing $ROADMAP_FILE"
  echo "      Run: $SCRIPT_DIR/ralph-roadmap.sh to define your product roadmap."
fi

if [ -f "$ACTIVE_SPRINT_FILE" ]; then
  ACTIVE_SPRINT="$(awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE" || true)"
  if [ -n "${ACTIVE_SPRINT:-}" ]; then
    STORIES_FILE="$(sprint_stories_file "$ACTIVE_SPRINT")"
    if [ -f "$STORIES_FILE" ]; then
      echo "OK: active sprint '$ACTIVE_SPRINT' has stories.json"
    else
      echo "WARN: active sprint '$ACTIVE_SPRINT' has no stories.json: $STORIES_FILE"
    fi
  fi
fi

tracked_legacy=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  tracked_legacy+="$path"$'\n'
done < <(git ls-files -- "${LEGACY_TRANSIENT_FILES[@]}" 2>/dev/null || true)
if [ -n "$tracked_legacy" ]; then
  echo "WARN: legacy transient Ralph files are still tracked in git:"
  printf '%s' "$tracked_legacy" | sed 's/^/      /'
  echo "      Remove them from git tracking after migration if they are no longer needed."
fi

case "$RALPH_HARNESS" in
  codex)
    if ! "$CODEX_BIN" exec --help >/dev/null 2>&1; then
      fail "Codex exec help failed. Check your Codex installation."
    fi

    if "$CODEX_BIN" --yolo exec --help 2>&1 | rg -qi "unexpected argument '--yolo'"; then
      echo "WARN: Your Codex does not support --yolo; ralph.sh will use a safe fallback."
    else
      echo "OK: codex --yolo available"
    fi
    ;;
  piagent)
    echo "OK: pi CLI available"
    if pi list 2>/dev/null | rg -q '(^|[[:space:]])(npm:)?pi-subagents(@|[[:space:]]|$)'; then
      echo "OK: pi-subagents extension installed"
    else
      echo "WARN: pi-subagents extension not found"
      echo "      Install it with: pi install npm:pi-subagents"
    fi
    ;;
esac

echo "OK: prerequisites present"
print_resolution_preview
