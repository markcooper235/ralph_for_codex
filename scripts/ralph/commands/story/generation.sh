#!/bin/bash
# Single-story container generation command.
#
# Lazy-loaded by ralph-story.sh for generate/specify preparation flows. The
# host supplies migration, backlog, harness, and preparation support helpers.

cmd_generate() {
  local story_id="${1:-}"
  [ -n "$story_id" ] || fail "Usage: ralph-story.sh generate <ID> [--dry-run] [--force]"
  shift || true
  local dry_run=0
  local force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      --force)   force=1;   shift ;;
      *) fail "Unknown generate option: $1" ;;
    esac
  done

  resolve_stories_file

  local story_meta
  story_meta="$(jq -r --arg id "$story_id" '.stories[] | select(.id == $id)' "$STORIES_FILE")"
  [ -n "$story_meta" ] || fail "Story $story_id not found in $STORIES_FILE"

  local raw_path
  raw_path="$(printf '%s' "$story_meta" | jq -r '.story_path // empty')"
  [ -n "$raw_path" ] || fail "story_path not set for $story_id in $STORIES_FILE"

  local story_path_abs
  story_path_abs="$(resolve_repo_relative_path "$raw_path")"

  local placeholder_recovery=0 existing_branch_name="" existing_prd_ref="" existing_prd_abs=""
  if [ -f "$story_path_abs" ]; then
    existing_branch_name="$(jq -r '.branchName // empty' "$story_path_abs" 2>/dev/null || true)"
    existing_prd_ref="$(jq -r '.spec.prdRef // empty' "$story_path_abs" 2>/dev/null || true)"
    if story_is_unrecovered_migration_placeholder "$story_path_abs"; then
      placeholder_recovery=1
      if [ -n "$existing_prd_ref" ]; then
        existing_prd_abs="$(resolve_repo_relative_path "$existing_prd_ref")"
      fi
    fi
  fi

  local title goal prompt_context effort sprint priority depends_on_arr
  local story_agent
  title="$(printf '%s' "$story_meta" | jq -r '.title // ""')"
  goal="$(printf '%s' "$story_meta" | jq -r '.goal // ""')"
  prompt_context="$(printf '%s' "$story_meta" | jq -r '.promptContext // ""')"
  story_agent="$(printf '%s' "$story_meta" | jq -r '.agent // ""')"
  effort="$(printf '%s' "$story_meta" | jq -r '.effort // 3')"
  priority="$(printf '%s' "$story_meta" | jq -r '.priority // 1')"
  sprint="$(printf '%s' "$story_meta" | jq -r '.sprint // empty')"
  [ -n "$sprint" ] || sprint="$(jq -r '.sprint // empty' "$STORIES_FILE")"
  require_story_sprint "$sprint" "$story_id"
  depends_on_arr="$(printf '%s' "$story_meta" | jq -c '.depends_on // []')"
  ensure_prep_run_dir "$sprint" "generate" >/dev/null

  local branch_name="ralph/$sprint/story-$story_id"
  [ -n "$existing_branch_name" ] && branch_name="$existing_branch_name"
  local project_name
  project_name="$(jq -r '.project // empty' "$STORIES_FILE")"
  [ -n "$project_name" ] || project_name="$(basename "$WORKSPACE_ROOT")"
  local story_dir specify_dir has_speckit
  story_dir="$(dirname "$story_path_abs")"
  specify_dir="$story_dir/.specify"
  local repo_briefing_abs repo_briefing_rel
  repo_briefing_abs="$(ensure_repo_briefing "$WORKSPACE_ROOT")"
  repo_briefing_rel="${repo_briefing_abs#$WORKSPACE_ROOT/}"
  has_speckit=0
  local command_map_json command_map_text prep_context_path prep_fingerprint existing_prep_fingerprint existing_generate_fingerprint
  command_map_json="$(build_project_command_map_json "$WORKSPACE_ROOT")"
  command_map_text="$(format_command_map_for_prompt "$command_map_json")"
  prep_context_path="$(story_prep_context_path "$story_dir")"
  prep_fingerprint="$(compute_story_prep_fingerprint \
    "$story_id" \
    "$sprint" \
    "$title" \
    "$goal" \
    "$prompt_context" \
    "" \
    "$command_map_json" \
    "$depends_on_arr" \
    "" \
    "")"
  existing_prep_fingerprint="$(read_story_prep_fingerprint "$prep_context_path")"
  existing_generate_fingerprint="$(read_story_generate_fingerprint "$prep_context_path")"
  if [ -n "$existing_prep_fingerprint" ]; then
    prep_fingerprint="$existing_prep_fingerprint"
  fi

  if [ ! -f "$prep_context_path" ]; then
    write_story_prep_context \
      "$prep_context_path" \
      "$story_id" \
      "$sprint" \
      "$title" \
      "$goal" \
      "$prompt_context" \
      "" \
      "$command_map_json" \
      "$depends_on_arr" \
      "" \
      "" \
      "$prep_fingerprint" \
      '[]'
  fi
  if [ ! -f "$(story_prep_bundle_context_path "$story_dir")" ] || [ ! -f "$(story_prep_bundle_commands_path "$story_dir")" ] || [ ! -f "$(story_prep_bundle_dependencies_path "$story_dir")" ] || [ ! -f "$(story_prep_bundle_schema_path "$story_dir")" ]; then
    write_story_prep_bundle \
      "$story_dir" \
      "$story_id" \
      "$sprint" \
      "$title" \
      "$goal" \
      "$prompt_context" \
      "" \
      "$command_map_json" \
      "$depends_on_arr" \
      '[]' \
      "$(jq -c '.dependencyStories // []' "$prep_context_path" 2>/dev/null || printf '[]')" \
      "$prep_fingerprint"
  fi

  if [ -f "$story_path_abs" ] && [ "$force" -eq 0 ] && [ -n "$existing_generate_fingerprint" ] && [ "$existing_generate_fingerprint" = "$prep_fingerprint" ]; then
    if [ ! -f "$(story_prep_bundle_capsule_path "$story_dir")" ]; then
      write_story_prep_capsule \
        "$story_dir" \
        "$story_id" \
        "$sprint" \
        "$title" \
        "$goal" \
        "$prompt_context" \
        "$repo_briefing_rel" \
        "$command_map_json" \
        "$depends_on_arr" \
        "$story_focus_files_json" \
        "$prep_fingerprint" \
        "${STORY_EXECUTION_PROFILE_JSON:-null}"
    fi
    echo "story.json up to date for $story_id (prep fingerprint match)"
    prep_record_stage "$story_id" "generate" "skipped" "story.json up to date (prep fingerprint match)" "$(jq -nc --arg path "$raw_path" --arg prep "$prep_context_path" '[$path, $prep]')" 0
    prep_finalize_if_mode "generate" "passed"
    return 0
  fi
  if [ -f "$story_path_abs" ] && [ "$force" -eq 0 ]; then
    fail "story.json already exists: $story_path_abs
  Use --force to overwrite."
  fi

  # Check for SpecKit artifacts (.specify/ in story directory)
  [ -f "$specify_dir/spec.md" ] && [ -f "$specify_dir/tasks.md" ] && has_speckit=1

  # Pull compact dependency handoff from the prep bundle when available.
  local dependency_bundle_json dep_context="" story_focus_files_json
  dependency_bundle_json="$(jq -c '.dependencyStories // []' "$prep_context_path" 2>/dev/null || printf '[]')"
  story_focus_files_json="$(jq -c '.likelyFiles // []' "$prep_context_path" 2>/dev/null || printf '[]')"
  dep_context="$(
    printf '%s\n' "$dependency_bundle_json" | jq -r '
      .[]?
      | "Prior story \(.storyId) (\(.title)):\n"
        + (if (.files // []) | length > 0 then "  Files: " + ((.files // []) | join(", ")) + "\n" else "" end)
        + (if (.invariants // "") != "" then "  Invariants: " + .invariants + "\n" else "" end)
        + (if (.notes // "") != "" then "  Notes: " + .notes + "\n" else "" end)
    ' 2>/dev/null || true
  )"

  local dep_section=""
  [ -n "$dep_context" ] && dep_section="Prior story results (dependencies):
$dep_context"

  local skill_instruction
  if [ "$has_speckit" -eq 1 ]; then
    skill_instruction="Use the SpecKit artifacts as the primary source:
- $specify_dir/spec.md
- $specify_dir/plan.md
- $specify_dir/tasks.md"
  elif [ "$placeholder_recovery" -eq 1 ]; then
    if [ -n "$existing_prd_ref" ] && [ -f "$existing_prd_abs" ]; then
      skill_instruction="Legacy migration placeholder detected — recover the story plan from the preserved PRD markdown.
Primary source PRD markdown: $existing_prd_abs

Use the story-generate skill and replace the placeholder entirely with a real story.json plan."
    else
      skill_instruction="Legacy migration placeholder detected, but the preserved PRD markdown is unavailable.
Recover the story plan from the backlog metadata below, using goal and planning context as the primary source.

Use the story-generate skill and replace the placeholder entirely with a real story.json plan."
    fi
  else
    skill_instruction="No SpecKit artifacts found.
Use the story-generate skill for schema and task design rules."
  fi

  local placeholder_section=""
  if [ "$placeholder_recovery" -eq 1 ]; then
    placeholder_section="Migration recovery:
- Existing story.json is a migration placeholder and should be fully replaced.
- Preserve storyId: $story_id
- Preserve branchName: $branch_name"
    if [ -n "$existing_prd_ref" ] && [ -f "$existing_prd_abs" ]; then
      placeholder_section="$placeholder_section
- Primary source markdown: $existing_prd_ref"
    else
      placeholder_section="$placeholder_section
- Primary source markdown unavailable; recover from goal and planning context."
    fi
  fi

  local prompt
  prompt="$(cat <<GENPROMPT
Generate story.json for $story_id.

Backlog: $project_name / $story_id / $title / sprint=$sprint / priority=$priority / effort=$effort
Goal: $goal
Context: $prompt_context
Depends on: $depends_on_arr
Agent profile: ${story_agent:-default}

$dep_section
$placeholder_section
$skill_instruction

Write the completed story.json to: $story_path_abs
Story capsule: $(story_prep_bundle_capsule_path "$story_dir")
Prep context: $prep_context_path
Prep bundle context: $(story_prep_bundle_context_path "$story_dir")
Prep bundle dependencies: $(story_prep_bundle_dependencies_path "$story_dir")
Prep bundle commands: $(story_prep_bundle_commands_path "$story_dir")
Prep bundle schema: $(story_prep_bundle_schema_path "$story_dir")

Use the story capsule as the compact summary and the prep bundle for schema, commands, and dependency handoff.

Verification commands:
$command_map_text

Requirements:
1. Use verification commands above; do not rediscover.
2. Prep bundle schema is authoritative for story.json shape. Keep exact top-level shape.
3. Set project=$project_name, sprint=$sprint, priority=$priority, depends_on=$depends_on_arr, status=planned, passes=false, branchName=$branch_name, and agent=${story_agent:-default}.
4. spec.scope is concise string. Task scope[] has repo-relative file paths. Task acceptance is single string. context is self-contained for fresh Codex session.
5. Create parent directory if needed. Do not commit.
6. Do not read Ralph framework docs or scripts for schema unless prep bundle schema is missing a required fact.
7. Do not read .prep-context.json, package.json, jest.config.ts, or tsconfig.json when prep bundle and SpecKit artifacts already provide schema, commands, and dependency handoff.
8. Do not narrate your plan or summarize your work.
GENPROMPT
)"

  if [ "$dry_run" -eq 1 ]; then
    if [ "$placeholder_recovery" -eq 1 ] && [ -n "$existing_prd_ref" ] && [ -f "$existing_prd_abs" ]; then
      echo "=== DRY RUN: deterministic migration recovery for $story_id ==="
      echo "Markdown source: $existing_prd_abs"
      echo "Output path:      $story_path_abs"
      echo "Branch name:      $branch_name"
      echo "Fallback:         guided Codex generation if markdown structure is unsupported"
      return 0
    fi
    echo "=== DRY RUN: generate prompt for $story_id ==="
    printf '%s\n' "$prompt"
    echo "=== Would write to: $story_path_abs ==="
    return 0
  fi

  local stage_started_at stage_duration_ms prep_execution_profile_json="null"
  stage_started_at="$(epoch_seconds)"
  echo "Generating story.json for $story_id..."
  mkdir -p "$(dirname "$story_path_abs")"
  local deterministic_recovery=0 prd_bridge_recovery=0 fallback_reason="" temp_bridge_prd=""
  story_harness_profile_push "$story_meta"
  prep_execution_profile_json="${STORY_EXECUTION_PROFILE_JSON:-null}"
  write_story_prep_capsule \
    "$story_dir" \
    "$story_id" \
    "$sprint" \
    "$title" \
    "$goal" \
    "$prompt_context" \
    "$repo_briefing_rel" \
    "$command_map_json" \
    "$depends_on_arr" \
    "$story_focus_files_json" \
    "$prep_fingerprint" \
    "$prep_execution_profile_json"
  prep_record_stage "$story_id" "generate" "running" "Generating story container" "$(jq -nc --arg path "$raw_path" --arg prep "$prep_context_path" '[$path, $prep]')" 0 "$prep_execution_profile_json"
  if [ "$placeholder_recovery" -eq 1 ] && [ -n "$existing_prd_ref" ] && [ -f "$existing_prd_abs" ]; then
    if parse_legacy_markdown_story_json \
      "$existing_prd_abs" \
      "$story_path_abs" \
      "$story_id" \
      "$title" \
      "$goal" \
      "$branch_name" \
      "$sprint" \
      "$priority" \
      "$depends_on_arr" \
      "$project_name"; then
      deterministic_recovery=1
      echo "Recovered migration placeholder for $story_id from legacy PRD markdown."
    else
      echo "WARN: deterministic markdown recovery could not parse $existing_prd_ref; trying temporary prd.json bridge."
      temp_bridge_prd="$(mktemp "${TMPDIR:-/tmp}/ralph-prd-bridge.json.XXXXXX")"
      if bridge_markdown_to_prd_json \
        "$existing_prd_abs" \
        "$temp_bridge_prd" \
        "$branch_name" \
        "$project_name" \
        "$title" \
        "$goal" \
        && build_story_json_from_prd_json \
          "$temp_bridge_prd" \
          "$story_path_abs" \
          "$story_id" \
          "$title" \
          "$goal" \
          "$branch_name" \
          "$sprint" \
          "$priority" \
          "$depends_on_arr" \
          "$project_name" \
          "$existing_prd_abs"; then
        prd_bridge_recovery=1
        echo "Recovered migration placeholder for $story_id through temporary prd.json bridge."
      else
        fallback_reason="Preserved PRD markdown could not be deterministically parsed or bridged through prd.json; guided fallback recovery was used."
        echo "WARN: temporary prd.json bridge recovery could not complete for $existing_prd_ref; falling back to guided generation."
      fi
    fi
  elif [ "$placeholder_recovery" -eq 1 ]; then
    fallback_reason="Preserved PRD markdown was unavailable; guided fallback recovery was used."
  fi

  if [ "$deterministic_recovery" -eq 0 ] && [ "$prd_bridge_recovery" -eq 0 ]; then
    prep_heartbeat_start "generate:$story_id"
    if ! harness_exec_prompt "$prompt" "$WORKSPACE_ROOT"; then
      prep_heartbeat_stop
      story_harness_profile_pop
      prep_fail_stage_and_exit "generate" "$story_id" "generate" "story.json generation failed for $story_id" "$(jq -nc --arg path "$raw_path" --arg prep "$prep_context_path" '[$path, $prep]')" "$prep_execution_profile_json"
    fi
    prep_heartbeat_stop
  fi
  story_harness_profile_pop

  if [ ! -f "$story_path_abs" ]; then
    fail "story.json was not written to: $story_path_abs"
  fi
  normalize_story_container "$story_path_abs"
  if [ -n "$story_agent" ]; then
    local tmp_story_with_agent
    tmp_story_with_agent="$(mktemp)"
    jq --arg agent "$story_agent" '.agent = $agent' "$story_path_abs" > "$tmp_story_with_agent"
    mv "$tmp_story_with_agent" "$story_path_abs"
  fi
  validate_story_container_file "$story_path_abs" "$story_id" "$sprint"
  if ! jq -e '.tasks | length > 0' "$story_path_abs" >/dev/null 2>&1; then
    fail "Generated story.json has no tasks: $story_path_abs"
  fi
  if ! jq -e '.storyId' "$story_path_abs" >/dev/null 2>&1; then
    fail "Generated story.json is missing storyId: $story_path_abs"
  fi

  if [ -n "$temp_bridge_prd" ] && [ -f "$temp_bridge_prd" ]; then
    rm -f "$temp_bridge_prd"
  fi

  if [ "$placeholder_recovery" -eq 1 ] && [ "$prd_bridge_recovery" -eq 1 ]; then
    mark_prd_bridge_migration_recovery "$story_path_abs" "$existing_prd_ref"
    echo "Annotated $story_id with temporary prd.json bridge provenance."
  elif [ "$placeholder_recovery" -eq 1 ] && [ "$deterministic_recovery" -eq 0 ]; then
    mark_guided_migration_recovery "$story_path_abs" "$fallback_reason" "$existing_prd_ref"
    echo "Annotated $story_id with guided migration recovery provenance."
  fi

  if [ "$placeholder_recovery" -eq 1 ]; then
    local tmp
    tmp="$(mktemp)"
    jq --arg id "$story_id" '
      .stories = (
        .stories
        | map(
            if .id == $id and .status == "blocked" then
              .status = "planned"
            else
              .
            end
          )
      )
    ' "$STORIES_FILE" > "$tmp"
    mv "$tmp" "$STORIES_FILE"
    echo "Recovered migration placeholder for $story_id; story status reset to planned."
  fi

  local task_count
  task_count="$(jq '.tasks | length' "$story_path_abs")"
  stage_duration_ms="$(( ($(epoch_seconds) - stage_started_at) * 1000 ))"
  write_story_generate_provenance "$prep_context_path" "$prep_fingerprint" "story.json" "$raw_path"
  prep_record_stage "$story_id" "generate" "passed" "Generated $task_count tasks" "$(jq -nc --arg path "$raw_path" --arg prep "$prep_context_path" '[$path, $prep]')" "$stage_duration_ms" "$prep_execution_profile_json"
  prep_finalize_if_mode "generate" "passed"
  echo "Generated: $raw_path ($task_count tasks)"
  echo "Run './ralph-story.sh health $story_id' to validate."
}
