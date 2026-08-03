#!/bin/bash
# Preparation runtime, journal, context-bundle, and fingerprint helpers.
#
# Lazy-loaded for specification, generation, and preparation commands. Sourcing
# this library performs no work. The host provides Ralph paths, harness helpers,
# and repository-specific search/SpecKit utilities.

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

epoch_seconds() {
  date +%s
}

prep_heartbeat_start() {
  local label="$1"
  prep_heartbeat_stop
  (
    local sleep_pid=""
    trap 'if [ -n "$sleep_pid" ]; then kill "$sleep_pid" 2>/dev/null || true; wait "$sleep_pid" 2>/dev/null || true; fi; exit 0' INT TERM
    local started_epoch
    started_epoch="$(epoch_seconds)"
    while true; do
      sleep "${RALPH_HEARTBEAT_INTERVAL_SECONDS:-45}" &
      sleep_pid=$!
      wait "$sleep_pid" || exit 0
      sleep_pid=""
      prep_touch_summary "${RALPH_PREP_PHASE:-unknown}" "${RALPH_PREP_ACTIVE_STORY_ID:-}" "${RALPH_PREP_ACTIVE_STAGE:-}" "${RALPH_PREP_EXECUTION_PROFILE_JSON:-null}"
      local elapsed
      elapsed=$(( $(epoch_seconds) - started_epoch ))
      echo "Heartbeat: prep phase=${RALPH_PREP_PHASE:-unknown} label=$label elapsed=${elapsed}s"
    done
  ) >> "${SCRIPT_DIR}/runtime/prep-heartbeat.log" 2>&1 &
  RALPH_PREP_HEARTBEAT_PID=$!
}

prep_heartbeat_stop() {
  if [ -n "${RALPH_PREP_HEARTBEAT_PID:-}" ] && kill -0 "$RALPH_PREP_HEARTBEAT_PID" 2>/dev/null; then
    kill "$RALPH_PREP_HEARTBEAT_PID" 2>/dev/null || true
    wait "$RALPH_PREP_HEARTBEAT_PID" 2>/dev/null || true
  fi
  RALPH_PREP_HEARTBEAT_PID=""
}

compact_text() {
  local value="${1:-}"
  local max_chars="${2:-280}"
  printf '%s' "$value" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//' \
    | awk -v limit="$max_chars" '{
        if (length($0) <= limit) {
          print $0
        } else {
          print substr($0, 1, limit - 3) "..."
        }
      }'
}

compact_list() {
  local value="${1:-}"
  local max_items="${2:-4}"
  [ -n "$value" ] || return 0
  printf '%s\n' "$value" \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed '/^$/d' \
    | awk -v limit="$max_items" '
        NR <= limit { items[NR] = $0 }
        END {
          for (i = 1; i <= NR && i <= limit; i++) {
            if (i > 1) printf ", "
            printf "%s", items[i]
          }
          if (NR > limit) printf ", ..."
          printf "\n"
        }
      '
}

prep_runtime_root() {
  printf '%s/runtime/prep-runs\n' "$SCRIPT_DIR"
}

latest_prep_summary_for_sprint() {
  local sprint="$1"
  local prep_root
  prep_root="$(prep_runtime_root)"
  [ -d "$prep_root" ] || return 1
  find "$prep_root" -type f -name 'prepare-run.json' -path "*-${sprint}-*/prepare-run.json" 2>/dev/null | sort | tail -n1
}

latest_prep_summary_any() {
  local prep_root
  prep_root="$(prep_runtime_root)"
  [ -d "$prep_root" ] || return 1
  find "$prep_root" -type f -name 'prepare-run.json' 2>/dev/null | sort | tail -n1
}

ensure_prep_run_dir() {
  local sprint="$1"
  local mode="${2:-prep}"
  if [ -n "${RALPH_PREP_RUN_DIR:-}" ]; then
    mkdir -p "$RALPH_PREP_RUN_DIR"
    printf '%s\n' "$RALPH_PREP_RUN_DIR"
    return 0
  fi

  local stamp run_dir
  stamp="$(date -u +"%Y%m%dT%H%M%SZ")"
  run_dir="$(prep_runtime_root)/${stamp}-${sprint}-${mode}"
  mkdir -p "$run_dir"
  cat > "$run_dir/prepare-run.json" <<EOF
{
  "version": 1,
  "mode": "$mode",
  "sprint": "$sprint",
  "started_at": "$(timestamp_utc)",
  "updated_at": "$(timestamp_utc)",
  "last_progress_at": "$(timestamp_utc)",
  "phase": "started",
  "active_story_id": null,
  "active_stage": null,
  "execution_profile": null,
  "stories": {}
}
EOF
  RALPH_PREP_RUN_DIR="$run_dir"
  export RALPH_PREP_RUN_DIR
  printf '%s\n' "$run_dir"
}

prep_summary_path() {
  [ -n "${RALPH_PREP_RUN_DIR:-}" ] || return 1
  printf '%s/prepare-run.json\n' "$RALPH_PREP_RUN_DIR"
}

prep_stage_log_path() {
  local story_id="$1"
  local stage="$2"
  [ -n "${RALPH_PREP_RUN_DIR:-}" ] || return 1
  printf '%s/%s-%s.log\n' "$RALPH_PREP_RUN_DIR" "$story_id" "$stage"
}

prep_stage_status_path() {
  local story_id="$1"
  local stage="$2"
  [ -n "${RALPH_PREP_RUN_DIR:-}" ] || return 1
  printf '%s/stages/%s-%s.json\n' "$RALPH_PREP_RUN_DIR" "$story_id" "$stage"
}

prep_collect_stage_rollup() {
  local summary_path="${1:-}"
  local stage_dir
  stage_dir="${2:-${RALPH_PREP_RUN_DIR:-}/stages}"

  if [ -z "$stage_dir" ] || [ ! -d "$stage_dir" ]; then
    printf '%s\n' '{"stories":{},"metrics":{"stage_count":0,"passed_stages":0,"skipped_stages":0,"failed_stages":0,"running_stages":0,"total_duration_ms":0},"active_story_id":null,"active_stage":null,"latest_execution_profile":null}'
    return 0
  fi

  find "$stage_dir" -type f -name '*.json' -print \
    | sort \
    | while IFS= read -r stage_file; do
        jq -c '.' "$stage_file"
      done \
    | jq -sc '
        . as $entries
        | {
            stories: (
              reduce $entries[] as $entry ({};
                .[$entry.storyId] = ((.[$entry.storyId] // {}) + {
                  ($entry.stage): {
                    status: $entry.status,
                    detail: $entry.detail,
                    artifacts: $entry.artifacts,
                    duration_ms: ($entry.duration_ms // 0),
                    updated_at: $entry.updated_at,
                    execution_profile: ($entry.execution_profile // null)
                  }
                })
              )
            ),
            metrics: {
              stage_count: ($entries | length),
              passed_stages: ($entries | map(select(.status == "passed")) | length),
              skipped_stages: ($entries | map(select(.status == "skipped")) | length),
              failed_stages: ($entries | map(select(.status == "failed")) | length),
              running_stages: ($entries | map(select(.status == "running")) | length),
              total_duration_ms: ($entries | map(.duration_ms // 0) | add // 0)
            },
            active_story_id: (
              $entries
              | map(select(.status == "running"))
              | sort_by(.updated_at, .storyId, .stage)
              | last
              | .storyId // null
            ),
            active_stage: (
              $entries
              | map(select(.status == "running"))
              | sort_by(.updated_at, .storyId, .stage)
              | last
              | .stage // null
            ),
            latest_execution_profile: (
              $entries
              | map(select(.execution_profile != null))
              | sort_by(.updated_at, .storyId, .stage)
              | last
              | .execution_profile // null
            )
          }
      '
}

prep_record_stage() {
  local story_id="$1"
  local stage="$2"
  local status="$3"
  local detail="${4:-}"
  local artifacts_json="${5:-[]}"
  local duration_ms="${6:-0}"
  local execution_profile_json="${7:-${STORY_EXECUTION_PROFILE_JSON:-null}}"
  RALPH_PREP_PHASE="${RALPH_PREP_PHASE:-$stage}"
  RALPH_PREP_ACTIVE_STORY_ID="$story_id"
  RALPH_PREP_ACTIVE_STAGE="$stage"
  RALPH_PREP_EXECUTION_PROFILE_JSON="$execution_profile_json"
  local stage_path
  stage_path="$(prep_stage_status_path "$story_id" "$stage" 2>/dev/null || true)"
  [ -n "$stage_path" ] || return 0
  mkdir -p "$(dirname "$stage_path")"
  jq -n \
    --arg storyId "$story_id" \
    --arg stage "$stage" \
    --arg status "$status" \
    --arg detail "$detail" \
    --arg updated_at "$(timestamp_utc)" \
    --argjson artifacts "$artifacts_json" \
    --argjson duration_ms "$duration_ms" \
    --argjson execution_profile "$execution_profile_json" \
    '{
      storyId: $storyId,
      stage: $stage,
      status: $status,
      detail: $detail,
      artifacts: $artifacts,
      duration_ms: $duration_ms,
      updated_at: $updated_at,
      execution_profile: (if $execution_profile == null then null else $execution_profile end)
    }' > "$stage_path"
  prep_touch_summary "${RALPH_PREP_PHASE:-$stage}" "$story_id" "$stage" "$execution_profile_json"
}

prep_touch_summary() {
  local phase="${1:-}"
  local active_story_id="${2:-}"
  local active_stage="${3:-}"
  local execution_profile_json="${4:-null}"
  RALPH_PREP_PHASE="${phase:-${RALPH_PREP_PHASE:-}}"
  RALPH_PREP_ACTIVE_STORY_ID="${active_story_id:-${RALPH_PREP_ACTIVE_STORY_ID:-}}"
  RALPH_PREP_ACTIVE_STAGE="${active_stage:-${RALPH_PREP_ACTIVE_STAGE:-}}"
  RALPH_PREP_EXECUTION_PROFILE_JSON="${execution_profile_json:-${RALPH_PREP_EXECUTION_PROFILE_JSON:-null}}"
  local summary_path tmp rollup_json effective_phase
  summary_path="$(prep_summary_path 2>/dev/null || true)"
  [ -n "$summary_path" ] && [ -f "$summary_path" ] || return 0
  rollup_json="$(prep_collect_stage_rollup "$summary_path")"
  effective_phase="$phase"
  if [ -n "$active_stage" ] && [ "$active_stage" != "null" ]; then
    case "$active_stage" in
      specify|generate)
        effective_phase="${active_stage}-all"
        ;;
    esac
  fi
  tmp="$(mktemp)"
  jq \
    --arg updated_at "$(timestamp_utc)" \
    --arg phase "$effective_phase" \
    --arg active_story_id "$active_story_id" \
    --arg active_stage "$active_stage" \
    --argjson execution_profile "$execution_profile_json" \
    --argjson rollup "$rollup_json" \
    '
      .updated_at = $updated_at
      | .last_progress_at = $updated_at
      | .phase = (if $phase == "" then (.phase // "running") else $phase end)
      | .active_story_id = (
          if $rollup.active_story_id != null then $rollup.active_story_id
          elif $active_story_id == "" then null
          else $active_story_id
          end
        )
      | .active_stage = (
          if $rollup.active_stage != null then $rollup.active_stage
          elif $active_stage == "" then null
          else $active_stage
          end
        )
      | .execution_profile = (
          if $execution_profile != null then $execution_profile
          elif $rollup.latest_execution_profile != null then $rollup.latest_execution_profile
          else (.execution_profile // null)
          end
        )
      | .stories = ($rollup.stories // (.stories // {}))
      | .metrics = ($rollup.metrics // (.metrics // null))
    ' "$summary_path" > "$tmp"
  mv "$tmp" "$summary_path"
}

prep_finalize_summary() {
  local final_status="$1"
  local summary_path tmp rollup_json
  summary_path="$(prep_summary_path 2>/dev/null || true)"
  [ -n "$summary_path" ] && [ -f "$summary_path" ] || return 0
  rollup_json="$(prep_collect_stage_rollup "$summary_path")"
  tmp="$(mktemp)"
  jq \
    --arg status "$final_status" \
    --arg finished_at "$(timestamp_utc)" \
    --argjson rollup "$rollup_json" \
    '.status = $status
      | .phase = $status
      | .finished_at = $finished_at
      | .updated_at = $finished_at
      | .last_progress_at = $finished_at
      | .active_story_id = null
      | .active_stage = null
      | .execution_profile = (
          if $rollup.latest_execution_profile != null then $rollup.latest_execution_profile
          else (.execution_profile // null)
          end
        )
      | .stories = ($rollup.stories // (.stories // {}))
      | .metrics = ($rollup.metrics // (.metrics // null))' \
    "$summary_path" > "$tmp"
  mv "$tmp" "$summary_path"
}

prep_finalize_if_mode() {
  local expected_mode="$1"
  local final_status="$2"
  local summary_path mode
  summary_path="$(prep_summary_path 2>/dev/null || true)"
  [ -n "$summary_path" ] && [ -f "$summary_path" ] || return 0
  mode="$(jq -r '.mode // empty' "$summary_path" 2>/dev/null || true)"
  [ "$mode" = "$expected_mode" ] || return 0
  prep_finalize_summary "$final_status"
}

prep_fail_stage_and_exit() {
  local mode="$1"
  local story_id="$2"
  local stage="$3"
  local detail="$4"
  local artifacts_json="${5:-[]}"
  local execution_profile_json="${6:-null}"
  prep_record_stage "$story_id" "$stage" "failed" "$detail" "$artifacts_json" 0 "$execution_profile_json"
  prep_finalize_if_mode "$mode" "failed"
  fail "$detail"
}

require_story_sprint() {
  local sprint_value="${1:-}"
  local story_id="${2:-story}"
  [ -n "$sprint_value" ] || fail "Story $story_id is missing sprint metadata in stories.json."
}

story_prep_context_path() {
  local story_dir="$1"
  printf '%s/.prep-context.json\n' "$story_dir"
}

story_prep_bundle_dir() {
  local story_dir="$1"
  printf '%s/.prep\n' "$story_dir"
}

story_prep_bundle_context_path() {
  local story_dir="$1"
  printf '%s/context.json\n' "$(story_prep_bundle_dir "$story_dir")"
}

story_prep_bundle_dependencies_path() {
  local story_dir="$1"
  printf '%s/dependencies.json\n' "$(story_prep_bundle_dir "$story_dir")"
}

story_prep_bundle_commands_path() {
  local story_dir="$1"
  printf '%s/commands.json\n' "$(story_prep_bundle_dir "$story_dir")"
}

story_prep_bundle_schema_path() {
  local story_dir="$1"
  printf '%s/schema.json\n' "$(story_prep_bundle_dir "$story_dir")"
}

story_prep_bundle_capsule_path() {
  local story_dir="$1"
  printf '%s/story-capsule.json\n' "$(story_prep_bundle_dir "$story_dir")"
}

focus_hints_to_json() {
  local focus_hints="${1:-}"
  local max_items="${2:-6}"
  if [ -n "$focus_hints" ]; then
    printf '%s\n' "$focus_hints" \
      | sed -n 's/^[[:space:]]*-[[:space:]]*`\(.*\)`$/\1/p' \
      | awk -v limit="$max_items" 'NR <= limit { print }' \
      | jq -R . \
      | jq -s .
  else
    printf '[]\n'
  fi
}

focus_hints_to_markdown() {
  local focus_hints="${1:-}"
  local max_items="${2:-6}"
  local focus_json

  focus_json="$(focus_hints_to_json "$focus_hints" "$max_items")"
  if [ "$focus_json" = "[]" ]; then
    return 0
  fi

  printf '%s\n' "$focus_json" | jq -r '.[] | "- `" + . + "`"'
}

write_story_prep_bundle() {
  local story_dir="$1"
  local story_id="$2"
  local sprint="$3"
  local title="$4"
  local goal="$5"
  local prompt_context="$6"
  local repo_briefing_rel="$7"
  local command_map_json="$8"
  local depends_on_json="$9"
  local likely_files_json="${10:-[]}"
  local dependency_bundle_json="${11:-[]}"
  local fingerprint="${12:-}"
  local bundle_dir context_path dependencies_path commands_path schema_path

  bundle_dir="$(story_prep_bundle_dir "$story_dir")"
  context_path="$(story_prep_bundle_context_path "$story_dir")"
  dependencies_path="$(story_prep_bundle_dependencies_path "$story_dir")"
  commands_path="$(story_prep_bundle_commands_path "$story_dir")"
  schema_path="$(story_prep_bundle_schema_path "$story_dir")"
  mkdir -p "$bundle_dir"

  jq -n \
    --arg storyId "$story_id" \
    --arg sprint "$sprint" \
    --arg title "$title" \
    --arg goal "$goal" \
    --arg promptContext "$prompt_context" \
    --arg repoBriefing "$repo_briefing_rel" \
    --arg fingerprint "$fingerprint" \
    --arg generatedAt "$(timestamp_utc)" \
    --argjson dependsOn "$depends_on_json" \
    --argjson likelyFiles "$likely_files_json" \
    '{
      version: 1,
      storyId: $storyId,
      sprint: $sprint,
      title: $title,
      goal: $goal,
      promptContext: $promptContext,
      repoBriefing: $repoBriefing,
      fingerprint: $fingerprint,
      dependsOn: $dependsOn,
      likelyFiles: $likelyFiles,
      generatedAt: $generatedAt
    }' > "$context_path"

  printf '%s\n' "$dependency_bundle_json" | jq '.' > "$dependencies_path"
  printf '%s\n' "$command_map_json" | jq '.' > "$commands_path"
  jq -n \
    --arg sprint "$sprint" \
    --arg title "$title" \
    --arg exampleBranch "ralph/${sprint}/story-S-001" \
    '{
      version: 1,
      container: {
        requiredTopLevel: [
          "version",
          "project",
          "storyId",
          "title",
          "description",
          "branchName",
          "sprint",
          "priority",
          "depends_on",
          "status",
          "spec",
          "tasks",
          "passes"
        ],
        requiredSpecFields: [
          "scope",
          "out_of_scope",
          "first_slice",
          "preserved_invariants",
          "supporting_files",
          "verification"
        ],
        requiredTaskFields: [
          "id",
          "title",
          "context",
          "scope",
          "acceptance",
          "checks",
          "depends_on",
          "status",
          "passes"
        ],
        topLevelDefaults: {
          version: 1,
          sprint: $sprint,
          status: "planned",
          passes: false
        },
        taskDefaults: {
          status: "pending",
          passes: false
        },
        taskStatusValues: ["pending", "done", "failed", "blocked"],
        fieldRules: [
          "spec.scope is a concise string summary, not an array",
          "task scope arrays must contain repo-relative concrete file paths",
          "task acceptance is a single string summary, not an array",
          "checks must be binary shell commands",
          "depends_on must reference task ids within the same story",
          "do not add extra top-level sections outside the standard story container"
        ],
        example: {
          version: 1,
          project: "repo-name",
          storyId: "S-001",
          title: $title,
          description: "Backlog goal for the story.",
          branchName: $exampleBranch,
          sprint: $sprint,
          priority: 1,
          depends_on: [],
          status: "planned",
          spec: {
            scope: "Concise summary of the work for this story.",
            out_of_scope: [],
            first_slice: {},
            preserved_invariants: [],
            supporting_files: [],
            verification: ["npm run test"]
          },
          tasks: [
            {
              id: "T-01",
              title: "Implement the main slice",
              context: "Self-contained implementation instructions for a fresh Codex session.",
              scope: ["lib/example.ts", "__tests__/example.test.ts"],
              acceptance: "Implementation exists and the targeted verification passes.",
              checks: ["npm run test"],
              depends_on: [],
              status: "pending",
              passes: false
            }
          ],
          passes: false
        }
      }
    }' > "$schema_path"
}

write_story_prep_capsule() {
  local story_dir="$1"
  local story_id="$2"
  local sprint="$3"
  local title="$4"
  local goal="$5"
  local prompt_context="$6"
  local repo_briefing_rel="$7"
  local command_map_json="$8"
  local depends_on_json="$9"
  local likely_files_json="${10:-[]}"
  local fingerprint="${11:-}"
  local execution_profile_json="${12:-null}"
  local capsule_path complexity_tier complexity_score execution_tier prompt_budget verification_commands_json harness model agent composite_profile

  capsule_path="$(story_prep_bundle_capsule_path "$story_dir")"
  mkdir -p "$(dirname "$capsule_path")"

  complexity_tier="$(printf '%s' "$execution_profile_json" | jq -r '.complexity_tier // "low"' 2>/dev/null || echo "low")"
  complexity_score="$(printf '%s' "$execution_profile_json" | jq -r '.complexity_score // 0' 2>/dev/null || echo 0)"
  execution_tier="$(printf '%s' "$execution_profile_json" | jq -r '.execution_tier // "simple"' 2>/dev/null || echo "simple")"
  harness="$(printf '%s' "$execution_profile_json" | jq -r '.harness // empty' 2>/dev/null || true)"
  model="$(printf '%s' "$execution_profile_json" | jq -r '.model // empty' 2>/dev/null || true)"
  agent="$(printf '%s' "$execution_profile_json" | jq -r '.agent // empty' 2>/dev/null || true)"
  composite_profile="$(printf '%s' "$execution_profile_json" | jq -r '.composite_profile // empty' 2>/dev/null || true)"

  case "$complexity_tier" in
    low) prompt_budget=1600 ;;
    medium) prompt_budget=2400 ;;
    high) prompt_budget=3200 ;;
    extreme) prompt_budget=4200 ;;
    *) prompt_budget=2000 ;;
  esac

  verification_commands_json="$(printf '%s\n' "$command_map_json" | jq -c '[.typecheck, .lint, .test, .build] | map(select(. != null and . != ""))')"

  jq -n \
    --arg version "1" \
    --arg storyId "$story_id" \
    --arg sprint "$sprint" \
    --arg title "$title" \
    --arg goal "$goal" \
    --arg promptContext "$prompt_context" \
    --arg repoBriefing "$repo_briefing_rel" \
    --arg fingerprint "$fingerprint" \
    --arg complexityTier "$complexity_tier" \
    --arg executionTier "$execution_tier" \
    --argjson complexityScore "$complexity_score" \
    --argjson promptBudget "$prompt_budget" \
    --argjson dependsOn "$depends_on_json" \
    --argjson seedFiles "$likely_files_json" \
    --argjson verificationCommands "$verification_commands_json" \
    --arg harness "$harness" \
    --arg model "$model" \
    --arg agent "$agent" \
    --arg compositeProfile "$composite_profile" \
    --arg generatedAt "$(timestamp_utc)" \
    '{
      version: ($version | tonumber),
      storyId: $storyId,
      sprint: $sprint,
      title: $title,
      goal: $goal,
      promptContext: $promptContext,
      repoBriefing: $repoBriefing,
      fingerprint: $fingerprint,
      harness: (if $harness == "" then null else $harness end),
      model: (if $model == "" then null else $model end),
      agent: (if $agent == "" then null else $agent end),
      compositeProfile: (if $compositeProfile == "" then null else $compositeProfile end),
      complexityTier: $complexityTier,
      complexityScore: $complexityScore,
      executionTier: $executionTier,
      promptBudget: $promptBudget,
      dependsOn: $dependsOn,
      seedFiles: $seedFiles,
      verificationCommands: $verificationCommands,
      generatedAt: $generatedAt
    }' > "$capsule_path"
}

write_story_prep_context() {
  local output_path="$1"
  local story_id="$2"
  local sprint="$3"
  local title="$4"
  local goal="$5"
  local prompt_context="$6"
  local repo_briefing_rel="$7"
  local command_map_json="$8"
  local depends_on_json="$9"
  local focus_hints="${10:-}"
  local dependency_context="${11:-}"
  local fingerprint="${12:-}"
  local dependency_bundle_json="${13:-[]}"

  local focus_json dependency_context_json existing_generation_json
  focus_json="$(focus_hints_to_json "$focus_hints")"
  dependency_context_json="$(printf '%s' "$dependency_context" | jq -Rs '.')"
  existing_generation_json='null'
  if [ -f "$output_path" ]; then
    existing_generation_json="$(jq -c --arg fingerprint "$fingerprint" '
      if (.fingerprint // "") == $fingerprint then
        (.generation // null)
      else
        null
      end
    ' "$output_path" 2>/dev/null || printf 'null')"
  fi
  mkdir -p "$(dirname "$output_path")"

  jq -n \
    --arg storyId "$story_id" \
    --arg sprint "$sprint" \
    --arg title "$title" \
    --arg goal "$goal" \
    --arg promptContext "$prompt_context" \
    --arg repoBriefing "$repo_briefing_rel" \
    --arg fingerprint "$fingerprint" \
    --arg generatedAt "$(timestamp_utc)" \
    --argjson commands "$command_map_json" \
    --argjson dependsOn "$depends_on_json" \
    --argjson likelyFiles "$focus_json" \
    --argjson dependencyContext "$dependency_context_json" \
    --argjson dependencyStories "$dependency_bundle_json" \
    --argjson generation "$existing_generation_json" \
    '{
      version: 1,
      storyId: $storyId,
      sprint: $sprint,
      title: $title,
      goal: $goal,
      promptContext: $promptContext,
      repoBriefing: $repoBriefing,
      fingerprint: $fingerprint,
      commands: $commands,
      dependsOn: $dependsOn,
      likelyFiles: $likelyFiles,
      dependencyContext: $dependencyContext,
      dependencyStories: $dependencyStories
    }
    + (if $generation == null then {} else {generation: $generation} end)
    + {
      generatedAt: $generatedAt
    }' > "$output_path"
}

format_command_map_for_prompt() {
  local command_map_json="$1"
  printf '%s' "$command_map_json" | jq -r '
    [
      "- typecheck: " + (.typecheck // "unavailable"),
      "- lint: " + (.lint // "unavailable"),
      "- test: " + (.test // "unavailable"),
      "- build: " + (.build // "unavailable")
    ] | join("\n")
  '
}

read_story_prep_fingerprint() {
  local prep_context_path="$1"
  [ -f "$prep_context_path" ] || return 0
  jq -r '.fingerprint // empty' "$prep_context_path" 2>/dev/null || true
}

read_story_generate_fingerprint() {
  local prep_context_path="$1"
  [ -f "$prep_context_path" ] || return 0
  jq -r '.generation.generatedFromFingerprint // empty' "$prep_context_path" 2>/dev/null || true
}

write_story_generate_provenance() {
  local prep_context_path="$1"
  local source_fingerprint="$2"
  local source_type="${3:-generated}"
  local story_path="$4"
  local tmp

  mkdir -p "$(dirname "$prep_context_path")"
  if [ -f "$prep_context_path" ]; then
    tmp="$(mktemp)"
    jq \
      --arg fingerprint "$source_fingerprint" \
      --arg source_type "$source_type" \
      --arg story_path "$story_path" \
      --arg generated_at "$(timestamp_utc)" \
      '.generation = {
        generatedFromFingerprint: $fingerprint,
        sourceType: $source_type,
        storyPath: $story_path,
        generatedAt: $generated_at
      }' \
      "$prep_context_path" > "$tmp"
    mv "$tmp" "$prep_context_path"
    return 0
  fi

  jq -n \
    --arg fingerprint "$source_fingerprint" \
    --arg source_type "$source_type" \
    --arg story_path "$story_path" \
    --arg generated_at "$(timestamp_utc)" \
    '{
      version: 1,
      fingerprint: $fingerprint,
      generatedAt: $generated_at,
      generation: {
        generatedFromFingerprint: $fingerprint,
        sourceType: $source_type,
        storyPath: $story_path,
        generatedAt: $generated_at
      }
    }' > "$prep_context_path"
}

specify_artifacts_complete() {
  local specify_dir="$1"
  [ -f "$specify_dir/spec.md" ] && [ -s "$specify_dir/spec.md" ] \
    && [ -f "$specify_dir/plan.md" ] && [ -s "$specify_dir/plan.md" ] \
    && [ -f "$specify_dir/tasks.md" ] && [ -s "$specify_dir/tasks.md" ]
}

hash_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r | awk '{print $1}'
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
    return 0
  fi
  fail "Missing SHA-256 hashing support (sha256sum, shasum, openssl, or python3)."
}

compute_story_prep_fingerprint() {
  local story_id="$1"
  local sprint="$2"
  local title="$3"
  local goal="$4"
  local prompt_context="$5"
  local repo_briefing_abs="$6"
  local command_map_json="$7"
  local depends_on_json="$8"
  local focus_hints="${9:-}"
  local dependency_context="${10:-}"
  local repo_briefing_hash focus_json dependency_context_json payload

  if [ -n "$repo_briefing_abs" ] && [ -f "$repo_briefing_abs" ]; then
    repo_briefing_hash="$(hash_text < "$repo_briefing_abs")"
  else
    repo_briefing_hash=""
  fi

  if [ -n "$focus_hints" ]; then
    focus_json="$(printf '%s\n' "$focus_hints" | sed -n 's/^[[:space:]]*-[[:space:]]*`\(.*\)`$/\1/p' | jq -R . | jq -s .)"
  else
    focus_json='[]'
  fi
  dependency_context_json="$(printf '%s' "$dependency_context" | jq -Rs '.')"

  payload="$(jq -nc \
    --arg storyId "$story_id" \
    --arg sprint "$sprint" \
    --arg title "$title" \
    --arg goal "$goal" \
    --arg promptContext "$prompt_context" \
    --arg repoBriefingHash "$repo_briefing_hash" \
    --argjson commands "$command_map_json" \
    --argjson dependsOn "$depends_on_json" \
    --argjson likelyFiles "$focus_json" \
    --argjson dependencyContext "$dependency_context_json" \
    '{
      storyId: $storyId,
      sprint: $sprint,
      title: $title,
      goal: $goal,
      promptContext: $promptContext,
      repoBriefingHash: $repoBriefingHash,
      commands: $commands,
      dependsOn: $dependsOn,
      likelyFiles: $likelyFiles,
      dependencyContext: $dependencyContext
    }')"
  printf '%s' "$payload" | hash_text
}

sanitize_dep_file_list() {
  local value="${1:-}"
  [ -n "$value" ] || return 0
  printf '%s\n' "$value" \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed '/^$/d' \
    | sanitize_specify_paths \
    | join_with_comma_space
}

