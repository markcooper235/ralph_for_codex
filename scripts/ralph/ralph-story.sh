#!/bin/bash
# ralph-story.sh — Story management for the story-task architecture.
#
# Stories replace epics as the sprint-level planning unit.
# Each story is a task container with its own story.json.
#
# Usage:
#   ./ralph-story.sh <command> [args]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPRINTS_DIR="$SCRIPT_DIR/sprints"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
STORIES_FILE="${RALPH_STORIES_FILE:-}"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CODEX_BIN="${CODEX_BIN:-codex}"

load_ralph_env() {
  local env_file="$1"
  [ -f "$env_file" ] || return 1
  set -a
  # shellcheck source=/dev/null
  . "$env_file"
  set +a
  return 0
}

# Load Ralph env so specify/generate use the same provider routing as story runs.
if ! load_ralph_env "${SCRIPT_DIR}/.ralph-env"; then
  load_ralph_env "${HOME}/.ralph-env" || true
fi

source "$SCRIPT_DIR/lib/sprint-layout.sh"
source "$SCRIPT_DIR/lib/harness-exec.sh"
source "$SCRIPT_DIR/lib/specify.sh"

fail() { echo "ERROR: $1" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }
require_cmd jq

story_harness_profile_push() {
  local story_meta_json="$1"
  local current_depth="${STORY_HARNESS_PROFILE_DEPTH:-0}"
  local effective_harness effective_agent tmp_story_meta

  if [ "$current_depth" -eq 0 ]; then
    STORY_HARNESS_PROFILE_ORIG_MODEL_SET=0
    if [ "${RALPH_MODEL+x}" = "x" ]; then
      STORY_HARNESS_PROFILE_ORIG_MODEL_SET=1
      STORY_HARNESS_PROFILE_ORIG_MODEL="${RALPH_MODEL:-}"
    else
      STORY_HARNESS_PROFILE_ORIG_MODEL=""
    fi

    STORY_HARNESS_PROFILE_ORIG_AGENT_SET=0
    if [ "${RALPH_AGENT+x}" = "x" ]; then
      STORY_HARNESS_PROFILE_ORIG_AGENT_SET=1
      STORY_HARNESS_PROFILE_ORIG_AGENT="${RALPH_AGENT:-}"
    else
      STORY_HARNESS_PROFILE_ORIG_AGENT=""
    fi

    STORY_HARNESS_PROFILE_ORIG_COMPOSITE_SET=0
    if [ "${RALPH_COMPOSITE_PROFILE+x}" = "x" ]; then
      STORY_HARNESS_PROFILE_ORIG_COMPOSITE_SET=1
      STORY_HARNESS_PROFILE_ORIG_COMPOSITE_PROFILE="${RALPH_COMPOSITE_PROFILE:-}"
      STORY_HARNESS_PROFILE_ORIG_COMPOSITE_PROFILE_JSON="${RALPH_COMPOSITE_PROFILE_JSON:-}"
      STORY_HARNESS_PROFILE_ORIG_COMPOSITE_SHAPE="${RALPH_COMPOSITE_SHAPE:-}"
      STORY_HARNESS_PROFILE_ORIG_COMPOSITE_REQUIRED_EXTENSIONS_JSON="${RALPH_COMPOSITE_REQUIRED_EXTENSIONS_JSON:-}"
      STORY_HARNESS_PROFILE_ORIG_COMPOSITE_SUBAGENT_ROLES_JSON="${RALPH_COMPOSITE_SUBAGENT_ROLES_JSON:-}"
      STORY_HARNESS_PROFILE_ORIG_COMPOSITE_STEPS_JSON="${RALPH_COMPOSITE_STEPS_JSON:-}"
    else
      STORY_HARNESS_PROFILE_ORIG_COMPOSITE_PROFILE=""
      STORY_HARNESS_PROFILE_ORIG_COMPOSITE_PROFILE_JSON=""
      STORY_HARNESS_PROFILE_ORIG_COMPOSITE_SHAPE=""
      STORY_HARNESS_PROFILE_ORIG_COMPOSITE_REQUIRED_EXTENSIONS_JSON=""
      STORY_HARNESS_PROFILE_ORIG_COMPOSITE_SUBAGENT_ROLES_JSON=""
      STORY_HARNESS_PROFILE_ORIG_COMPOSITE_STEPS_JSON=""
    fi

    STORY_HARNESS_PROFILE_ORIG_HARNESS_OVERRIDE_SET=0
    if [ "${RALPH_HARNESS_OVERRIDE+x}" = "x" ]; then
      STORY_HARNESS_PROFILE_ORIG_HARNESS_OVERRIDE_SET=1
      STORY_HARNESS_PROFILE_ORIG_HARNESS_OVERRIDE="${RALPH_HARNESS_OVERRIDE:-}"
    else
      STORY_HARNESS_PROFILE_ORIG_HARNESS_OVERRIDE=""
    fi

    STORY_HARNESS_PROFILE_ORIG_HARNESS_SELECTION_SOURCE_SET=0
    if [ "${RALPH_HARNESS_SELECTION_SOURCE+x}" = "x" ]; then
      STORY_HARNESS_PROFILE_ORIG_HARNESS_SELECTION_SOURCE_SET=1
      STORY_HARNESS_PROFILE_ORIG_HARNESS_SELECTION_SOURCE="${RALPH_HARNESS_SELECTION_SOURCE:-}"
    else
      STORY_HARNESS_PROFILE_ORIG_HARNESS_SELECTION_SOURCE=""
    fi

    tmp_story_meta="$(mktemp)"
    printf '%s' "$story_meta_json" | jq '{
      title: (.title // ""),
      description: (.goal // .description // ""),
      tasks: [{ title: (.promptContext // "") }],
      labels: (.labels // []),
      tags: (.tags // []),
      agent: (.agent // empty)
    }' > "$tmp_story_meta"

    local explicit_story_agent
    explicit_story_agent="$(printf '%s' "$story_meta_json" | jq -r '.agent // empty' 2>/dev/null || true)"
    if [ -n "${RALPH_AGENT:-}" ] || [ -n "$explicit_story_agent" ]; then
      RALPH_AGENT_SELECTION_SOURCE="explicit"
    else
      RALPH_AGENT_SELECTION_SOURCE=""
    fi
    effective_agent="$(_get_effective_agent "$tmp_story_meta")"
    if [ -z "${RALPH_AGENT_SELECTION_SOURCE:-}" ]; then
      if [ "$effective_agent" != "default" ]; then
        RALPH_AGENT_SELECTION_SOURCE="inferred"
      else
        RALPH_AGENT_SELECTION_SOURCE="default"
      fi
    fi
    export RALPH_AGENT_SELECTION_SOURCE
    local complexity_pair complexity_score complexity_tier
    complexity_pair="$(_story_complexity_score "$story_meta_json")"
    complexity_score="${complexity_pair%%:*}"
    complexity_tier="${complexity_pair#*:}"
    rm -f "$tmp_story_meta"

    STORY_HARNESS_EFFECTIVE_AGENT="$effective_agent"
    STORY_COMPLEXITY_SCORE="$complexity_score"
    STORY_COMPLEXITY_TIER="$complexity_tier"
    STORY_EXECUTION_PROFILE_JSON=""
    export STORY_COMPLEXITY_SCORE STORY_COMPLEXITY_TIER
    _apply_agent_profile "$effective_agent"
    effective_harness="$(_get_harness)"
    STORY_EXECUTION_PROFILE_JSON="$(get_execution_profile_json "$effective_agent")"
    export STORY_EXECUTION_PROFILE_JSON
    local execution_tier
    execution_tier="$(printf '%s' "$STORY_EXECUTION_PROFILE_JSON" | jq -r '.execution_tier // empty' 2>/dev/null || true)"

    if [ -n "${RALPH_MODEL:-}" ]; then
      if [ -n "${RALPH_COMPOSITE_PROFILE:-}" ]; then
        echo "Selected harness profile: harness=$effective_harness agent=$effective_agent model=$RALPH_MODEL composite=$RALPH_COMPOSITE_PROFILE tier=${execution_tier:-unknown} complexity=$STORY_COMPLEXITY_TIER($STORY_COMPLEXITY_SCORE)"
      else
        echo "Selected harness profile: harness=$effective_harness agent=$effective_agent model=$RALPH_MODEL tier=${execution_tier:-unknown} complexity=$STORY_COMPLEXITY_TIER($STORY_COMPLEXITY_SCORE)"
      fi
    else
      if [ -n "${RALPH_COMPOSITE_PROFILE:-}" ]; then
        echo "Selected harness profile: harness=$effective_harness agent=$effective_agent composite=$RALPH_COMPOSITE_PROFILE tier=${execution_tier:-unknown} complexity=$STORY_COMPLEXITY_TIER($STORY_COMPLEXITY_SCORE)"
      else
        echo "Selected harness profile: harness=$effective_harness agent=$effective_agent tier=${execution_tier:-unknown} complexity=$STORY_COMPLEXITY_TIER($STORY_COMPLEXITY_SCORE)"
      fi
    fi
  fi

  STORY_HARNESS_PROFILE_DEPTH=$((current_depth + 1))
}

story_harness_profile_pop() {
  local current_depth="${STORY_HARNESS_PROFILE_DEPTH:-0}"
  [ "$current_depth" -gt 0 ] || return 0

  current_depth=$((current_depth - 1))
  STORY_HARNESS_PROFILE_DEPTH="$current_depth"

  if [ "$current_depth" -eq 0 ]; then
    if [ "${STORY_HARNESS_PROFILE_ORIG_MODEL_SET:-0}" -eq 1 ]; then
      RALPH_MODEL="${STORY_HARNESS_PROFILE_ORIG_MODEL:-}"
      export RALPH_MODEL
    else
      unset RALPH_MODEL
    fi

    if [ "${STORY_HARNESS_PROFILE_ORIG_AGENT_SET:-0}" -eq 1 ]; then
      RALPH_AGENT="${STORY_HARNESS_PROFILE_ORIG_AGENT:-}"
      export RALPH_AGENT
    else
      unset RALPH_AGENT
    fi

    if [ "${STORY_HARNESS_PROFILE_ORIG_COMPOSITE_SET:-0}" -eq 1 ]; then
      RALPH_COMPOSITE_PROFILE="${STORY_HARNESS_PROFILE_ORIG_COMPOSITE_PROFILE:-}"
      RALPH_COMPOSITE_PROFILE_JSON="${STORY_HARNESS_PROFILE_ORIG_COMPOSITE_PROFILE_JSON:-}"
      RALPH_COMPOSITE_SHAPE="${STORY_HARNESS_PROFILE_ORIG_COMPOSITE_SHAPE:-}"
      RALPH_COMPOSITE_REQUIRED_EXTENSIONS_JSON="${STORY_HARNESS_PROFILE_ORIG_COMPOSITE_REQUIRED_EXTENSIONS_JSON:-}"
      RALPH_COMPOSITE_SUBAGENT_ROLES_JSON="${STORY_HARNESS_PROFILE_ORIG_COMPOSITE_SUBAGENT_ROLES_JSON:-}"
      RALPH_COMPOSITE_STEPS_JSON="${STORY_HARNESS_PROFILE_ORIG_COMPOSITE_STEPS_JSON:-}"
      export RALPH_COMPOSITE_PROFILE RALPH_COMPOSITE_PROFILE_JSON RALPH_COMPOSITE_SHAPE \
        RALPH_COMPOSITE_REQUIRED_EXTENSIONS_JSON RALPH_COMPOSITE_SUBAGENT_ROLES_JSON \
        RALPH_COMPOSITE_STEPS_JSON
    else
      unset RALPH_COMPOSITE_PROFILE RALPH_COMPOSITE_PROFILE_JSON RALPH_COMPOSITE_SHAPE \
        RALPH_COMPOSITE_REQUIRED_EXTENSIONS_JSON RALPH_COMPOSITE_SUBAGENT_ROLES_JSON \
        RALPH_COMPOSITE_STEPS_JSON
    fi

    if [ "${STORY_HARNESS_PROFILE_ORIG_HARNESS_OVERRIDE_SET:-0}" -eq 1 ]; then
      RALPH_HARNESS_OVERRIDE="${STORY_HARNESS_PROFILE_ORIG_HARNESS_OVERRIDE:-}"
      export RALPH_HARNESS_OVERRIDE
    else
      unset RALPH_HARNESS_OVERRIDE
    fi

    if [ "${STORY_HARNESS_PROFILE_ORIG_HARNESS_SELECTION_SOURCE_SET:-0}" -eq 1 ]; then
      RALPH_HARNESS_SELECTION_SOURCE="${STORY_HARNESS_PROFILE_ORIG_HARNESS_SELECTION_SOURCE:-}"
      export RALPH_HARNESS_SELECTION_SOURCE
    else
      unset RALPH_HARNESS_SELECTION_SOURCE
    fi

    unset STORY_HARNESS_PROFILE_ORIG_MODEL_SET
    unset STORY_HARNESS_PROFILE_ORIG_MODEL
    unset STORY_HARNESS_PROFILE_ORIG_AGENT_SET
    unset STORY_HARNESS_PROFILE_ORIG_AGENT
    unset STORY_HARNESS_PROFILE_ORIG_COMPOSITE_SET
    unset STORY_HARNESS_PROFILE_ORIG_COMPOSITE_PROFILE
    unset STORY_HARNESS_PROFILE_ORIG_COMPOSITE_PROFILE_JSON
    unset STORY_HARNESS_PROFILE_ORIG_COMPOSITE_SHAPE
    unset STORY_HARNESS_PROFILE_ORIG_COMPOSITE_REQUIRED_EXTENSIONS_JSON
    unset STORY_HARNESS_PROFILE_ORIG_COMPOSITE_SUBAGENT_ROLES_JSON
    unset STORY_HARNESS_PROFILE_ORIG_COMPOSITE_STEPS_JSON
    unset STORY_HARNESS_PROFILE_ORIG_HARNESS_OVERRIDE_SET
    unset STORY_HARNESS_PROFILE_ORIG_HARNESS_OVERRIDE
    unset STORY_HARNESS_PROFILE_ORIG_HARNESS_SELECTION_SOURCE_SET
    unset STORY_HARNESS_PROFILE_ORIG_HARNESS_SELECTION_SOURCE
    unset STORY_HARNESS_EFFECTIVE_AGENT
    unset STORY_COMPLEXITY_SCORE
    unset STORY_COMPLEXITY_TIER
    unset STORY_EXECUTION_PROFILE_JSON
    unset RALPH_MODEL_SELECTION_SOURCE
    unset RALPH_AGENT_SELECTION_SOURCE
    unset STORY_HARNESS_PROFILE_DEPTH
  fi
}

# Preparation support is lazy-loaded from lib/story-preparation.sh.

branch_parent_from_upstream() {
  local branch="$1"
  git -C "$WORKSPACE_ROOT" for-each-ref --format='%(upstream:short)' "refs/heads/$branch" 2>/dev/null | head -n1
}

set_branch_parent() {
  local branch="$1"
  local parent="$2"
  [ -n "$branch" ] && [ -n "$parent" ] || return 0
  git -C "$WORKSPACE_ROOT" branch --set-upstream-to="$parent" "$branch" >/dev/null 2>&1 || true
}

get_active_sprint() {
  [ -f "$ACTIVE_SPRINT_FILE" ] || return 1
  awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE"
}

resolve_stories_file() {
  if [ -n "$STORIES_FILE" ]; then
    [ -f "$STORIES_FILE" ] || fail "Stories file not found: $STORIES_FILE"
    return
  fi

  local active_sprint
  active_sprint="$(get_active_sprint)" || fail "No active sprint. Use ralph-sprint.sh use <sprint-name>."

  STORIES_FILE="$(sprint_stories_file "$active_sprint")"
  [ -f "$STORIES_FILE" ] || fail "No stories.json for sprint '$active_sprint'. Run ralph-roadmap.sh or create the sprint backlog first."
}

resolve_stories_file_for_sprint() {
  local sprint_name="$1"
  [ -n "$sprint_name" ] || fail "Missing sprint name."
  STORIES_FILE="$(sprint_stories_file "$sprint_name")"
  [ -f "$STORIES_FILE" ] || fail "No stories.json for sprint '$sprint_name'. Run ralph-roadmap.sh or create the sprint backlog first."
}

usage() {
  cat <<'EOF'
Usage: ./ralph-story.sh <command> [args]

Commands:
  list                       List all stories in the active sprint
  show <ID>                  Show full story.json for a story
  next                       Show the next eligible story (no blockers, lowest priority)
  next-id                    Print only the next eligible story ID
  use <ID>                   Set a story as the active story
  start-next                 Set next eligible story as active
  tasks <ID>                 List tasks in a story with their status
  set-status <ID> <STATUS>   Set story status (planned|ready|active|done|abandoned|blocked)
  abandon <ID> [REASON]      Mark story abandoned
  health [ID]                Validate active stories (excludes done/abandoned)
  health-all                 Full audit sweep including done/abandoned stories
  specify <ID>               Run SpecKit analysis then generate story.json (primary path)
  specify-all [--force] [--jobs N]  Run SpecKit for all pending stories (default: serial)
  generate <ID>              Generate story.json (uses SpecKit artifacts when present)
  generate-all [--force] [--jobs N] Generate story.json for all stories with SpecKit artifacts
  prepare-all [--force] [--jobs N]  specify-all + generate-all + health only
  prep-status [options]      Show latest prep journal summary for a sprint
  import-prd [PATH]          Import prd.json userStories into sprint backlog
  import-story <ID> <PATH|-] Import a story.json via framework validation
  add [options]              Add a story non-interactively

Eligibility for "next":
  - status is ready or planned
  - all depends_on stories are done
  - lowest priority wins, then ID

Specify options:
  --dry-run                  Print plan without running
  --force                    Re-run SpecKit even if artifacts exist
  --no-generate              Stop after SpecKit analysis (skip story.json generation)

Generate options:
  --dry-run                  Print the Codex prompt without running
  --force                    Overwrite existing story.json

Prep-status options:
  --sprint NAME              Inspect a specific sprint (default: active sprint)
  --story ID                 Limit detail output to one story
  --details                  Include per-stage detail lines
  --story-limit N            Limit compact story output (default: 5)

Import-prd options:
  PATH                       Path to prd.json (default: scripts/ralph/prd.json)

Add options:
  --id S-XXX                 Explicit story ID (default: next sequential)
  --title TEXT               Story title (required)
  --agent NAME               Explicit agent/profile name
  --priority N               Priority (default: next available)
  --effort N                 Effort: 1, 2, 3, or 5 (default: 3)
  --status STATUS            planned|ready (default: planned)
  --depends-on IDS           Comma-separated dependency IDs (repeatable)
  --prompt-context TEXT      Planning context for story generation
  --goal TEXT                Story goal description
EOF
}

# ---------------------------------------------------------------------------
# Resolve story file path (absolute)
# ---------------------------------------------------------------------------

resolve_story_path() {
  local story_id="$1"
  local raw_path
  raw_path="$(jq -r --arg id "$story_id" '.stories[] | select(.id == $id) | .story_path // empty' "$STORIES_FILE")"
  [ -n "$raw_path" ] || fail "Story $story_id not found in $STORIES_FILE"

  if [[ "$raw_path" != /* ]]; then
    echo "$WORKSPACE_ROOT/$raw_path"
  else
    echo "$raw_path"
  fi
}

resolve_repo_relative_path() {
  local raw_path="$1"
  if [[ "$raw_path" != /* ]]; then
    printf '%s\n' "$WORKSPACE_ROOT/$raw_path"
  else
    printf '%s\n' "$raw_path"
  fi
}

story_exists_in_backlog() {
  local story_id="$1"
  jq -e --arg id "$story_id" '.stories[] | select(.id == $id)' "$STORIES_FILE" >/dev/null 2>&1
}

parse_depends_on_args() {
  local story_id="${1:-}"
  shift || true
  local values=()
  local raw dep
  for raw in "$@"; do
    [ -n "$raw" ] || continue
    while IFS= read -r dep; do
      dep="$(printf '%s' "$dep" | awk '{$1=$1;print}')"
      [ -n "$dep" ] || continue
      [ "$dep" != "$story_id" ] || fail "Story $story_id cannot depend on itself."
      story_exists_in_backlog "$dep" || fail "Unknown dependency '$dep'. Add the story first."
      values+=("$dep")
    done < <(printf '%s\n' "$raw" | tr ',' '\n')
  done

  if [ "${#values[@]}" -eq 0 ]; then
    printf '[]\n'
    return 0
  fi

  printf '%s\n' "${values[@]}" \
    | awk 'NF && !seen[$0]++' \
    | jq -R . \
    | jq -s .
}

normalize_story_container() {
  local story_path="$1"
  local tmp
  tmp="$(mktemp)"
  jq '
    (.tasks // []) |= map(
      .depends_on =
        (if (.depends_on | type) == "array" then .depends_on
         elif (.depends_on | type) == "string" then [ .depends_on ]
         else [] end)
    )
    | (.tasks // []) |= (
      . as $all
      | reduce range(length) as $_ (
          { rem: $all, done: [] };
          (.done | map(.id)) as $placed
          | (
              .rem
              | map(select(
                  (.depends_on // []) | all(.[]; . as $d | $placed | index($d) != null)
                ))
              | sort_by(
                  if   (.id    | test("final$"))
                    or (.title | test("(?i)regression|final"))              then 99
                  elif (.title | test("(?i)test|spec"))                     then 20
                  elif (.title | test("(?i)integrat|home.*page|page.*app")) then 10
                  elif (.title | test("(?i)implement|create|build|librar")) then  5
                  elif (.title | test("(?i)confirm|depend|prerequisit"))    then  0
                  else 10 end
                )
              | .[0]
            ) as $next
          | if $next then
              {
                rem: (.rem | map(select(.id != $next.id))),
                done: (.done + [
                  ($next | .checks |= map(
                    if type == "string" then
                      (if test("^rg ") then
                         gsub("\\\\(?<c>[^ntrfaebsvdDwWsSpPhH0-9\\\\/\"])"; .c)
                       else . end)
                      | (if test("^rg \"[^\"]+\" [^ ]+$") then
                           capture("^rg \"(?<pat>[^\"]+)\" (?<file>[^ ]+)$")
                           | "rg -Fq \"\(.pat)\" \(.file) 2>/dev/null"
                         elif test("^rg -[a-zA-Z]+ \"[^\"]+\" [^ ]+$") then
                           capture("^rg -[a-zA-Z]+ \"(?<pat>[^\"]+)\" (?<file>[^ ]+)$")
                           | "rg -Fq \"\(.pat)\" \(.file) 2>/dev/null"
                         else . end)
                    else . end
                  ))
                ])
              }
            else .
            end
        )
      | .done
    )
  ' "$story_path" > "$tmp"
  mv "$tmp" "$story_path"
}

validate_story_container_file() {
  local story_path="$1"
  local expected_story_id="$2"
  local expected_sprint="$3"

  jq -e '.' "$story_path" >/dev/null 2>&1 || fail "Invalid JSON: $story_path"
  jq -e --arg id "$expected_story_id" '.storyId == $id' "$story_path" >/dev/null 2>&1 \
    || fail "Imported story.json storyId must be $expected_story_id"
  jq -e --arg sprint "$expected_sprint" '.sprint == $sprint' "$story_path" >/dev/null 2>&1 \
    || fail "Imported story.json sprint must be $expected_sprint"
  jq -e '.tasks | type == "array" and length > 0' "$story_path" >/dev/null 2>&1 \
    || fail "Imported story.json must contain tasks[]"
  jq -e 'all(.tasks[]; (.checks | type) == "array" and (.checks | length) > 0)' "$story_path" >/dev/null 2>&1 \
    || fail "Imported story.json has task(s) without checks"

  local bad_check=0 check
  while IFS= read -r check; do
    bash -n <<< "$check" 2>/dev/null || bad_check=$((bad_check + 1))
  done < <(jq -r '.tasks[].checks[]' "$story_path")
  [ "$bad_check" -eq 0 ] || fail "Imported story.json contains shell-invalid checks"
}

story_is_unrecovered_migration_placeholder() {
  local story_path="$1"
  [ -f "$story_path" ] || return 1
  jq -e '.migration.tasks_recovered == false' "$story_path" >/dev/null 2>&1
}

infer_checks_from_text() {
  local text="$1"
  local checks="[]"

  if printf '%s\n' "$text" | rg -qi '(^|[^[:alnum:]_])(typecheck|tsc|type check|type-check)($|[^[:alnum:]_])'; then
    checks="$(echo "$checks" | jq '. + ["npm run typecheck"]')"
  fi
  if printf '%s\n' "$text" | rg -qi '(^|[^[:alnum:]_])(test|tests|jest|vitest|pytest|go test)($|[^[:alnum:]_])'; then
    checks="$(echo "$checks" | jq '. + ["npm test"]')"
  fi
  if printf '%s\n' "$text" | rg -qi '(^|[^[:alnum:]_])(lint|eslint)($|[^[:alnum:]_])'; then
    checks="$(echo "$checks" | jq '. + ["npm run lint"]')"
  fi
  if printf '%s\n' "$text" | rg -qi '(^|[^[:alnum:]_])(build)($|[^[:alnum:]_])'; then
    checks="$(echo "$checks" | jq '. + ["npm run build"]')"
  fi
  if printf '%s\n' "$text" | rg -qi 'verify in browser|playwright|cypress|verification'; then
    checks="$(echo "$checks" | jq '. + ["echo browser verification required"]')"
  fi

  if [ "$checks" = "[]" ]; then
    checks='["npm run typecheck"]'
  fi

  echo "$checks"
}

extract_markdown_section_body() {
  local file="$1"
  local heading="$2"
  awk -v heading="$heading" '
    $0 == heading { in_section=1; next }
    in_section && /^## / { exit }
    in_section { print }
  ' "$file"
}

extract_markdown_section_body_any() {
  local file="$1"
  shift
  local heading body
  for heading in "$@"; do
    body="$(extract_markdown_section_body "$file" "$heading")"
    if [ -n "$(printf '%s\n' "$body" | awk 'NF { print; exit }')" ]; then
      printf '%s\n' "$body"
      return 0
    fi
  done
  return 1
}

json_array_from_markdown_bullets() {
  local text="$1"
  printf '%s\n' "$text" \
    | sed -n -E 's/^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]*//p' \
    | awk 'NF' \
    | jq -R . \
    | jq -s .
}

json_first_slice_from_markdown() {
  local text="$1"
  local source destination entrypoint
  source="$(printf '%s\n' "$text" | sed -n 's/^[[:space:]]*-[[:space:]]*exact source:[[:space:]]*//Ip' | head -n 1)"
  destination="$(printf '%s\n' "$text" | sed -n 's/^[[:space:]]*-[[:space:]]*destination:[[:space:]]*//Ip' | head -n 1)"
  entrypoint="$(printf '%s\n' "$text" | sed -n 's/^[[:space:]]*-[[:space:]]*\(entrypoint\|workflow\|commands\|caller workflow\):[[:space:]]*//Ip' | head -n 1)"
  jq -n \
    --arg source "$source" \
    --arg destination "$destination" \
    --arg entrypoint "$entrypoint" \
    '{
      source: $source,
      destination: $destination,
      entrypoint: $entrypoint
    }'
}

json_scope_from_text() {
  local text="$1"
  {
    printf '%s\n' "$text" | rg -o '`[^`]+`' | tr -d '`' || true
    printf '%s\n' "$text" | rg -o '([A-Za-z0-9._-]+/)+[A-Za-z0-9._-]+' || true
    printf '%s\n' "$text" | rg -o '([A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+\.[A-Za-z0-9._-]+' || true
  } \
    | sed -E 's/^[("'\''`]+//; s/[)"'\''`.,;:]+$//' \
    | awk 'NF && !seen[$0]++' \
    | jq -R . \
    | jq -s '
        unique
        | map(select(length > 0)) as $all
        | $all
        | map(select(
            . as $candidate
            | ($all | any(. != $candidate and endswith("/" + $candidate))) | not
          ))
      '
}

scope_fallback_from_spec() {
  local task_scope_json="$1"
  local support_json="$2"
  local first_slice_json="$3"
  printf '%s' "$task_scope_json" | jq \
    --argjson support "$support_json" \
    --argjson first_slice "$first_slice_json" \
    '
      if length > 0 then
        .
      else
        (
          (($support // []) + [($first_slice.destination // empty), ($first_slice.source // empty)])
          | map(select(type == "string" and length > 0))
          | map(sub("^[./]+"; ""))
          | map(select(test("\\.(md|txt)$") | not))
          | unique
        )
      end
    '
}

task_id_from_prd_story() {
  local raw_id="$1"
  local fallback_index="$2"
  local num
  num="$(printf '%s\n' "$raw_id" | sed -n 's/^US-\?0*\([0-9][0-9]*\)$/\1/p')"
  if [ -n "$num" ]; then
    printf 'T-%02d\n' "$num"
  else
    printf 'T-%02d\n' "$fallback_index"
  fi
}

parse_legacy_markdown_story_json() {
  local markdown_path="$1"
  local output_path="$2"
  local story_id="$3"
  local title="$4"
  local description="$5"
  local branch_name="$6"
  local sprint="$7"
  local priority="$8"
  local depends_json="$9"
  local project_name="${10}"

  [ -f "$markdown_path" ] || return 1

  local user_stories_body scope_body out_scope_body slice_body support_body invariants_body definition_body
  user_stories_body="$(extract_markdown_section_body_any "$markdown_path" '## User Stories' '## Stories' '## Implementation Stories' || true)"
  [ -n "$user_stories_body" ] || return 1

  if ! printf '%s\n' "$user_stories_body" | rg -q '^(### ([Ss]tory[[:space:]]+[0-9]+:|[0-9]+[.)][[:space:]]+|[^#].+)|[Ss]tory[[:space:]]+[[:alnum:]]+([:.-][[:space:]].*)?)'; then
    return 1
  fi

  scope_body="$(extract_markdown_section_body_any "$markdown_path" '## Scope' '## In Scope' || true)"
  out_scope_body="$(extract_markdown_section_body_any "$markdown_path" '## Out of Scope' '## Not In Scope' || true)"
  slice_body="$(extract_markdown_section_body_any "$markdown_path" '## First Slice Expectations' '## First Slice' '## Initial Slice' || true)"
  support_body="$(extract_markdown_section_body_any "$markdown_path" '## Allowed Supporting Files' '## Supporting Files' '## Files in Scope' || true)"
  invariants_body="$(extract_markdown_section_body_any "$markdown_path" '## Preserved Invariants' '## Invariants' || true)"
  definition_body="$(extract_markdown_section_body_any "$markdown_path" '## Definition of Done' '## Verification' '## Done Criteria' || true)"

  local spec_scope
  spec_scope="$(printf '%s\n' "$scope_body" | awk 'NF { print }' | paste -sd ' ' -)"
  [ -n "$spec_scope" ] || spec_scope="$description"

  local out_scope_json invariants_json support_json verification_json first_slice_json
  out_scope_json="$(json_array_from_markdown_bullets "$out_scope_body")"
  invariants_json="$(json_array_from_markdown_bullets "$invariants_body")"
  support_json="$(json_array_from_markdown_bullets "$support_body")"
  verification_json="$(json_array_from_markdown_bullets "$definition_body")"
  first_slice_json="$(json_first_slice_from_markdown "$slice_body")"

  local tasks_json
  tasks_json="$(
    printf '%s\n' "$user_stories_body" | awk '
      BEGIN {
        task_index = 0
        state = ""
        title = ""
        desc = ""
        acceptance = ""
        proof = ""
      }
      function trim(str) {
        gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", str)
        return str
      }
      function emit_task() {
        if (title == "") return
        task_index += 1
        gsub(/\n+$/, "", desc)
        gsub(/\n+$/, "", acceptance)
        gsub(/\n+$/, "", proof)
        printf("{\"id\":\"T-%02d\",\"title\":%s,\"desc\":%s,\"acceptance\":%s,\"proof\":%s}\n",
          task_index,
          tojson(trim(title)),
          tojson(trim(desc)),
          tojson(trim(acceptance)),
          tojson(trim(proof)))
      }
      function tojson(str,    out, i, c) {
        out = "\""
        for (i = 1; i <= length(str); i++) {
          c = substr(str, i, 1)
          if (c == "\\") out = out "\\\\"
          else if (c == "\"") out = out "\\\""
          else if (c == "\n") out = out "\\n"
          else out = out c
        }
        return out "\""
      }
      function normalize_title(raw,    cleaned) {
        cleaned = raw
        sub(/^###[[:space:]]*/, "", cleaned)
        sub(/^[Ss]tory[[:space:]]+[0-9]+:[[:space:]]*/, "", cleaned)
        sub(/^[0-9]+[.)][[:space:]]*/, "", cleaned)
        sub(/^[Ss]tory[[:space:]]+[[:alnum:]]+[[:space:]]*[-:][[:space:]]*/, "", cleaned)
        sub(/^[*][*](.*)[*][*]$/, "\\1", cleaned)
        return trim(cleaned)
      }
      function is_story_heading(raw,    probe) {
        probe = raw
        if (probe ~ /^### /) return 1
        if (probe ~ /^[Ss]tory[[:space:]]+[[:alnum:]]+([:.-][[:space:]].*)?$/) return 1
        return 0
      }
      /^[#[:space:]]*\**Acceptance Criteria:?\**[[:space:]]*$/ { state = "accept"; next }
      /^[#[:space:]]*\**Proof Obligations:?\**[[:space:]]*$/ { state = "proof"; next }
      /^[#[:space:]]*\**Description:?\**[[:space:]]*$/ { state = "desc"; next }
      /^[#[:space:]]*\**Description:[[:space:]]+/ {
        sub(/^[#[:space:]]*\**Description:[[:space:]]*/, "", $0)
        state = "desc"
        if (desc == "") desc = $0
        else desc = desc "\n" $0
        next
      }
      {
        if (is_story_heading($0)) {
          emit_task()
          title = normalize_title($0)
          if (title == "" || title ~ /^[Ss]tory[[:space:]]+[[:alnum:]]+$/) {
            title = trim($0)
            sub(/^###[[:space:]]*/, "", title)
          }
          desc = ""
          acceptance = ""
          proof = ""
          state = "desc"
          next
        }
        if ($0 ~ /^[#[:space:]]*\**Acceptance Criteria:?\**[[:space:]]*$/) { state = "accept"; next }
        if ($0 ~ /^[#[:space:]]*\**Proof Obligations:?\**[[:space:]]*$/) { state = "proof"; next }
        if ($0 ~ /^[#[:space:]]*\**Description:?\**[[:space:]]*$/) { state = "desc"; next }
        if (state == "desc") {
          if (desc == "") desc = $0
          else desc = desc "\n" $0
        } else if (state == "accept" && $0 ~ /^[[:space:]]*([-*]|[0-9]+[.)])/) {
          sub(/^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]*/, "", $0)
          if (acceptance == "") acceptance = $0
          else acceptance = acceptance "\n" $0
        } else if (state == "proof" && $0 ~ /^[[:space:]]*([-*]|[0-9]+[.)])/) {
          sub(/^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]*/, "", $0)
          if (proof == "") proof = $0
          else proof = proof "\n" $0
        } else if (state == "desc" && $0 ~ /^[[:space:]]*$/) {
          next
        }
      }
      END { emit_task() }
    ' | jq -Rs '
      split("\n")
      | map(select(length > 0) | fromjson)
    '
  )"

  local final_tasks_json="[]"
  local previous_task_id=""
  while IFS= read -r task_row; do
    [ -n "$task_row" ] || continue
    local task_id task_title task_desc task_acceptance_block task_proof_block
    local task_context task_acceptance_summary scope_text scope_json checks_json depends_task
    task_id="$(printf '%s' "$task_row" | jq -r '.id')"
    task_title="$(printf '%s' "$task_row" | jq -r '.title')"
    task_desc="$(printf '%s' "$task_row" | jq -r '.desc')"
    task_acceptance_block="$(printf '%s' "$task_row" | jq -r '.acceptance')"
    task_proof_block="$(printf '%s' "$task_row" | jq -r '.proof')"

    task_context="$task_desc"
    if [ -n "$task_acceptance_block" ]; then
      if [ -n "$task_context" ]; then
        task_context="$task_context"$'\n\n'"Acceptance Criteria:"$'\n'
      else
        task_context="Acceptance Criteria:"$'\n'
      fi
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        task_context="$task_context- $line"$'\n'
      done < <(printf '%s\n' "$task_acceptance_block")
    fi
    if [ -n "$task_proof_block" ]; then
      if [ -n "$task_context" ]; then
        task_context="$task_context"$'\n'"Proof Obligations:"$'\n'
      else
        task_context="Proof Obligations:"$'\n'
      fi
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        task_context="$task_context- $line"$'\n'
      done < <(printf '%s\n' "$task_proof_block")
    fi
    task_context="${task_context%$'\n'}"
    [ -n "$task_context" ] || task_context="Recover implementation details from preserved legacy PRD markdown."

    task_acceptance_summary="$(printf '%s\n%s\n' "$task_acceptance_block" "$task_proof_block" | awk 'NF { print }' | paste -sd ' ' -)"
    [ -n "$task_acceptance_summary" ] || task_acceptance_summary="$task_title completed according to legacy PRD markdown."

    scope_text="$(printf '%s\n%s\n%s\n' "$task_desc" "$task_acceptance_block" "$task_proof_block")"
    scope_json="$(json_scope_from_text "$scope_text")"
    scope_json="$(scope_fallback_from_spec "$scope_json" "$support_json" "$first_slice_json")"
    checks_json="$(infer_checks_from_text "$task_acceptance_summary")"
    depends_task="[]"
    if [ -n "$previous_task_id" ]; then
      depends_task="$(jq -nc --arg dep "$previous_task_id" '[$dep]')"
    fi
    final_tasks_json="$(printf '%s' "$final_tasks_json" | jq \
      --arg id "$task_id" \
      --arg title "$task_title" \
      --arg context "$task_context" \
      --arg acceptance "$task_acceptance_summary" \
      --argjson scope "$scope_json" \
      --argjson checks "$checks_json" \
      --argjson depends "$depends_task" \
      '. + [{
        "id": $id,
        "title": $title,
        "context": $context,
        "scope": $scope,
        "acceptance": $acceptance,
        "checks": $checks,
        "depends_on": $depends,
        "status": "pending",
        "passes": false
      }]')"
    previous_task_id="$task_id"
  done < <(printf '%s' "$tasks_json" | jq -c '.[]')

  [ "$(printf '%s' "$final_tasks_json" | jq 'length')" -gt 0 ] || return 1

  local prd_ref="$markdown_path"
  if [[ "$prd_ref" == "$WORKSPACE_ROOT/"* ]]; then
    prd_ref="${prd_ref#$WORKSPACE_ROOT/}"
  fi

  jq -n \
    --argjson version 1 \
    --arg project "$project_name" \
    --arg sid "$story_id" \
    --arg title "$title" \
    --arg desc "$description" \
    --arg branch "$branch_name" \
    --arg sprint "$sprint" \
    --argjson priority "$priority" \
    --argjson depends "$depends_json" \
    --arg scope "$spec_scope" \
    --argjson out_scope "$out_scope_json" \
    --argjson first_slice "$first_slice_json" \
    --argjson invariants "$invariants_json" \
    --argjson support "$support_json" \
    --argjson verification "$verification_json" \
    --arg prd_ref "$prd_ref" \
    --argjson tasks "$final_tasks_json" \
    '{
      "version": $version,
      "project": $project,
      "storyId": $sid,
      "title": $title,
      "description": $desc,
      "branchName": $branch,
      "sprint": $sprint,
      "priority": $priority,
      "depends_on": $depends,
      "status": "planned",
      "spec": {
        "scope": $scope,
        "out_of_scope": $out_scope,
        "first_slice": $first_slice,
        "preserved_invariants": $invariants,
        "supporting_files": $support,
        "verification": $verification,
        "prdRef": $prd_ref
      },
      "migration": {
        "source": "legacy-prd-markdown",
        "tasks_recovered": true
      },
      "tasks": $tasks,
      "passes": false
    }' > "$output_path"
}

mark_guided_migration_recovery() {
  local story_path="$1"
  local fallback_reason="$2"
  local prd_ref="$3"
  local tmp
  tmp="$(mktemp)"
  jq \
    --arg reason "$fallback_reason" \
    --arg prd_ref "$prd_ref" \
    '
      .migration = ((.migration // {}) + {
        source: "legacy-placeholder-guided-recovery",
        tasks_recovered: true,
        recoveryMode: "guided-codex-fallback",
        recoveryWarnings: (
          [
            "Task plan was regenerated through guided fallback recovery rather than deterministic legacy markdown compilation.",
            $reason
          ]
          | map(select(length > 0))
        )
      })
      | if ($prd_ref | length) > 0 then
          .spec = ((.spec // {}) + { prdRef: $prd_ref })
        else
          .
        end
      | .spec.verification = (
          ((.spec.verification // []) + [
            "Legacy migration fallback recovery used guided generation; review task scope and acceptance checks before execution."
          ])
          | unique
        )
    ' "$story_path" > "$tmp"
  mv "$tmp" "$story_path"
}

mark_prd_bridge_migration_recovery() {
  local story_path="$1"
  local prd_ref="$2"
  local tmp
  tmp="$(mktemp)"
  jq \
    --arg prd_ref "$prd_ref" \
    '
      .migration = ((.migration // {}) + {
        source: "legacy-prd-json-bridge",
        tasks_recovered: true,
        recoveryMode: "guided-prd-json-bridge",
        recoveryWarnings: [
          "Task plan was recovered by converting preserved PRD markdown into a temporary prd.json bridge before generating story.json."
        ]
      })
      | if ($prd_ref | length) > 0 then
          .spec = ((.spec // {}) + { prdRef: $prd_ref })
        else
          .
        end
      | .spec.verification = (
          ((.spec.verification // []) + [
            "Legacy migration used a temporary prd.json bridge; review generated tasks and acceptance checks before execution."
          ])
          | unique
        )
    ' "$story_path" > "$tmp"
  mv "$tmp" "$story_path"
}

bridge_markdown_to_prd_json() {
  local markdown_path="$1"
  local temp_prd_path="$2"
  local branch_name="$3"
  local project_name="$4"
  local story_title="$5"
  local story_goal="$6"

  local prompt
  prompt="$(cat <<PRDBRIDGE
## Recover temporary prd.json for legacy migration

Source PRD markdown: $markdown_path

Use the PRD skill to normalize the markdown structure, then use the Ralph PRD converter rules to produce a valid temporary prd.json for migration recovery.

Write the temporary prd.json to: $temp_prd_path

Requirements:
1. project: $project_name
2. branchName: $branch_name
3. description should summarize: $story_goal
4. Preserve the PRD intent, but split oversized work into focused userStories when needed.
5. Every user story must include verifiable acceptance criteria and "Typecheck passes".
6. Add "Tests pass" and lint/browser verification only when the markdown warrants it.
7. Set every story to passes=false and notes="".
8. Do not write story.json in this step.
PRDBRIDGE
)"

  harness_exec_prompt "$prompt" "$WORKSPACE_ROOT"
  [ -f "$temp_prd_path" ] || return 1
  jq -e '.userStories | length > 0' "$temp_prd_path" >/dev/null 2>&1
}

build_story_json_from_prd_json() {
  local prd_json_path="$1"
  local output_path="$2"
  local story_id="$3"
  local title="$4"
  local description="$5"
  local branch_name="$6"
  local sprint="$7"
  local priority="$8"
  local depends_json="$9"
  local project_name="${10}"
  local markdown_path="${11:-}"

  [ -f "$prd_json_path" ] || return 1
  jq -e '.userStories | length > 0' "$prd_json_path" >/dev/null 2>&1 || return 1

  local scope_body out_scope_body slice_body support_body invariants_body definition_body
  local spec_scope out_scope_json invariants_json support_json verification_json first_slice_json

  if [ -n "$markdown_path" ] && [ -f "$markdown_path" ]; then
    scope_body="$(extract_markdown_section_body_any "$markdown_path" '## Scope' '## In Scope' || true)"
    out_scope_body="$(extract_markdown_section_body_any "$markdown_path" '## Out of Scope' '## Not In Scope' || true)"
    slice_body="$(extract_markdown_section_body_any "$markdown_path" '## First Slice Expectations' '## First Slice' '## Initial Slice' || true)"
    support_body="$(extract_markdown_section_body_any "$markdown_path" '## Allowed Supporting Files' '## Supporting Files' '## Files in Scope' || true)"
    invariants_body="$(extract_markdown_section_body_any "$markdown_path" '## Preserved Invariants' '## Invariants' || true)"
    definition_body="$(extract_markdown_section_body_any "$markdown_path" '## Definition of Done' '## Verification' '## Done Criteria' || true)"
  else
    scope_body=""
    out_scope_body=""
    slice_body=""
    support_body=""
    invariants_body=""
    definition_body=""
  fi

  spec_scope="$(printf '%s\n' "$scope_body" | awk 'NF { print }' | paste -sd ' ' -)"
  [ -n "$spec_scope" ] || spec_scope="$(jq -r '.description // empty' "$prd_json_path")"
  [ -n "$spec_scope" ] || spec_scope="$description"
  out_scope_json="$(json_array_from_markdown_bullets "$out_scope_body")"
  invariants_json="$(json_array_from_markdown_bullets "$invariants_body")"
  support_json="$(json_array_from_markdown_bullets "$support_body")"
  verification_json="$(json_array_from_markdown_bullets "$definition_body")"
  first_slice_json="$(json_first_slice_from_markdown "$slice_body")"

  local final_tasks_json="[]"
  local previous_task_id=""
  local index=1
  while IFS= read -r us_row; do
    [ -n "$us_row" ] || continue
    local raw_us_id task_id us_title us_desc us_acceptance us_scope us_context acceptance_summary checks_json depends_task
    raw_us_id="$(printf '%s' "$us_row" | jq -r '.id // empty')"
    task_id="$(task_id_from_prd_story "$raw_us_id" "$index")"
    us_title="$(printf '%s' "$us_row" | jq -r '.title // ""')"
    us_desc="$(printf '%s' "$us_row" | jq -r '.description // ""')"
    us_acceptance="$(printf '%s' "$us_row" | jq -c '.acceptanceCriteria // []')"
    us_scope="$(printf '%s' "$us_row" | jq -c '.scopePaths // []')"
    us_context="$us_desc"
    if [ "$(printf '%s' "$us_acceptance" | jq 'length')" -gt 0 ]; then
      local ac_lines
      ac_lines="$(printf '%s' "$us_acceptance" | jq -r '.[]' | sed 's/^/- /')"
      if [ -n "$us_context" ]; then
        us_context="$us_context"$'\n\n'"Acceptance Criteria:"$'\n'"$ac_lines"
      else
        us_context="Acceptance Criteria:"$'\n'"$ac_lines"
      fi
    fi
    acceptance_summary="$(printf '%s' "$us_acceptance" | jq -r 'join(". ")')"
    [ -n "$acceptance_summary" ] || acceptance_summary="$us_title completed according to temporary prd.json recovery."
    checks_json="$(infer_checks_from_text "$(printf '%s' "$us_acceptance" | jq -r 'join(" ")')")"
    us_scope="$(scope_fallback_from_spec "$us_scope" "$support_json" "$first_slice_json")"
    depends_task="[]"
    if [ -n "$previous_task_id" ]; then
      depends_task="$(jq -nc --arg dep "$previous_task_id" '[$dep]')"
    fi
    final_tasks_json="$(printf '%s' "$final_tasks_json" | jq \
      --arg id "$task_id" \
      --arg title "$us_title" \
      --arg context "$us_context" \
      --arg acceptance "$acceptance_summary" \
      --argjson scope "$us_scope" \
      --argjson checks "$checks_json" \
      --argjson depends "$depends_task" \
      '. + [{
        "id": $id,
        "title": $title,
        "context": $context,
        "scope": $scope,
        "acceptance": $acceptance,
        "checks": $checks,
        "depends_on": $depends,
        "status": "pending",
        "passes": false
      }]')"
    previous_task_id="$task_id"
    index=$((index + 1))
  done < <(jq -c '.userStories[]' "$prd_json_path")

  [ "$(printf '%s' "$final_tasks_json" | jq 'length')" -gt 0 ] || return 1

  local prd_ref="$markdown_path"
  if [ -n "$prd_ref" ] && [[ "$prd_ref" == "$WORKSPACE_ROOT/"* ]]; then
    prd_ref="${prd_ref#$WORKSPACE_ROOT/}"
  fi

  jq -n \
    --argjson version 1 \
    --arg project "$project_name" \
    --arg sid "$story_id" \
    --arg title "$title" \
    --arg desc "$description" \
    --arg branch "$branch_name" \
    --arg sprint "$sprint" \
    --argjson priority "$priority" \
    --argjson depends "$depends_json" \
    --arg scope "$spec_scope" \
    --argjson out_scope "$out_scope_json" \
    --argjson first_slice "$first_slice_json" \
    --argjson invariants "$invariants_json" \
    --argjson support "$support_json" \
    --argjson verification "$verification_json" \
    --arg prd_ref "$prd_ref" \
    --argjson tasks "$final_tasks_json" \
    '{
      "version": $version,
      "project": $project,
      "storyId": $sid,
      "title": $title,
      "description": $desc,
      "branchName": $branch,
      "sprint": $sprint,
      "priority": $priority,
      "depends_on": $depends,
      "status": "planned",
      "spec": {
        "scope": $scope,
        "out_of_scope": $out_scope,
        "first_slice": $first_slice,
        "preserved_invariants": $invariants,
        "supporting_files": $support,
        "verification": $verification,
        "prdRef": $prd_ref
      },
      "tasks": $tasks,
      "passes": false
    }' > "$output_path"
}

# Lifecycle commands are lazy-loaded from commands/story/lifecycle.sh.

# Health commands are lazy-loaded from commands/story/health.sh.

# Authoring commands are lazy-loaded from commands/story/authoring.sh.

# Generation command is lazy-loaded from commands/story/generation.sh.

# PRD import is lazy-loaded with commands/story/authoring.sh.

# Specification command is lazy-loaded from commands/story/specification.sh.

# Batch preparation commands are lazy-loaded from commands/story/preparation.sh.

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

CMD="${1:-}"
shift || true

case "$CMD" in
  specify|specify-all|generate|generate-all|prepare-all|prep-status)
    # shellcheck source=lib/story-preparation.sh
    source "$SCRIPT_DIR/lib/story-preparation.sh"
    ;;
esac

case "$CMD" in
  generate|generate-all|specify|specify-all|prepare-all)
    # specify delegates to generation unless --no-generate is used.
    # shellcheck source=commands/story/generation.sh
    source "$SCRIPT_DIR/commands/story/generation.sh"
    ;;
esac

case "$CMD" in
  specify|specify-all|prepare-all)
    # shellcheck source=commands/story/specification.sh
    source "$SCRIPT_DIR/commands/story/specification.sh"
    ;;
esac

case "$CMD" in
  list|show|next|next-id|use|start-next|tasks|set-status|abandon)
    # shellcheck source=commands/story/lifecycle.sh
    source "$SCRIPT_DIR/commands/story/lifecycle.sh"
    ;;
esac

case "$CMD" in
  health|health-all|prepare-all)
    # prepare-all calls the same validator after specification and generation.
    # shellcheck source=commands/story/health.sh
    source "$SCRIPT_DIR/commands/story/health.sh"
    ;;
esac

case "$CMD" in
  add|import-story|import-prd)
    # shellcheck source=commands/story/authoring.sh
    source "$SCRIPT_DIR/commands/story/authoring.sh"
    ;;
esac

case "$CMD" in
  specify-all|generate-all|prepare-all|prep-status)
    # shellcheck source=commands/story/preparation.sh
    source "$SCRIPT_DIR/commands/story/preparation.sh"
    ;;
esac

case "$CMD" in
  list)         cmd_list ;;
  show)         cmd_show "$@" ;;
  next)         cmd_next ;;
  next-id)      cmd_next_id ;;
  use)          cmd_use "$@" ;;
  start-next)   cmd_start_next ;;
  tasks)        cmd_tasks "$@" ;;
  set-status)   cmd_set_status "$@" ;;
  abandon)      cmd_abandon "$@" ;;
  health)       cmd_health "$@" ;;
  specify)      cmd_specify "$@" ;;
  specify-all)  cmd_specify_all "$@" ;;
  generate)     cmd_generate "$@" ;;
  generate-all) cmd_generate_all "$@" ;;
  health-all)   cmd_health_all ;;
  prepare-all)  cmd_prepare_all "$@" ;;
  prep-status)  cmd_prep_status "$@" ;;
  import-prd)   cmd_import_prd "$@" ;;
  import-story) cmd_import_story "$@" ;;
  add)          cmd_add "$@" ;;
  -h|--help|"") usage; exit 0 ;;
  *) fail "Unknown command: $CMD. Use --help for usage." ;;
esac
