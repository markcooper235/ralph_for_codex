#!/bin/bash
# Single-story SpecKit specification command.
#
# Lazy-loaded by ralph-story.sh. The host supplies story metadata, harness,
# SpecKit, generation, and preparation support helpers.

cmd_specify() {
  local story_id="${1:-}"
  [ -n "$story_id" ] || fail "Usage: ralph-story.sh specify <ID> [--dry-run] [--force] [--no-generate]"
  shift || true
  local dry_run=0 force=0 no_generate=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)     dry_run=1;     shift ;;
      --force)       force=1;       shift ;;
      --no-generate) no_generate=1; shift ;;
      *) fail "Unknown specify option: $1" ;;
    esac
  done

  resolve_stories_file

  local story_meta
  story_meta="$(jq -r --arg id "$story_id" '.stories[] | select(.id == $id)' "$STORIES_FILE")"
  [ -n "$story_meta" ] || fail "Story $story_id not found in $STORIES_FILE"

  local raw_path
  raw_path="$(printf '%s' "$story_meta" | jq -r '.story_path // empty')"
  [ -n "$raw_path" ] || fail "story_path not set for $story_id"

  local story_path_abs story_dir specify_dir
  [[ "$raw_path" != /* ]] && story_path_abs="$WORKSPACE_ROOT/$raw_path" || story_path_abs="$raw_path"
  story_dir="$(dirname "$story_path_abs")"
  specify_dir="$story_dir/.specify"
  local repo_briefing_abs repo_briefing_rel
  repo_briefing_abs="$(ensure_repo_briefing "$WORKSPACE_ROOT")"
  repo_briefing_rel="${repo_briefing_abs#$WORKSPACE_ROOT/}"
  local story_focus_text story_focus_hints="" story_focus_files_json=""

  # Detect specify binary — required, no fallback
  local specify_bin=""
  specify_bin="$(find_specify_bin)" || fail "'specify' CLI not found and 'npx specify' unavailable.
  Install the CLI: uv tool install git+https://github.com/github/spec-kit.git
  Or use:          npx --yes specify version
  Or re-run: bash install.sh --install-speckit"
  echo "SpecKit: $specify_bin"

  # Extract story metadata
  local title goal prompt_context effort sprint priority depends_on_arr
  title="$(printf '%s' "$story_meta" | jq -r '.title // ""')"
  goal="$(printf '%s' "$story_meta" | jq -r '.goal // ""')"
  prompt_context="$(printf '%s' "$story_meta" | jq -r '.promptContext // ""')"
  effort="$(printf '%s' "$story_meta" | jq -r '.effort // 3')"
  sprint="$(printf '%s' "$story_meta" | jq -r '.sprint // empty')"
  [ -n "$sprint" ] || sprint="$(jq -r '.sprint // empty' "$STORIES_FILE")"
  require_story_sprint "$sprint" "$story_id"
  priority="$(printf '%s' "$story_meta" | jq -r '.priority // 1')"
  depends_on_arr="$(printf '%s' "$story_meta" | jq -c '.depends_on // []')"
  story_focus_text="$(printf '%s\n%s\n%s\n' "$title" "$goal" "$prompt_context")"
  story_focus_hints="$(collect_story_focus_hints "$WORKSPACE_ROOT" "$story_focus_text" || true)"
  story_focus_files_json="$(focus_hints_to_json "$story_focus_hints")"
  ensure_prep_run_dir "$sprint" "specify" >/dev/null

  # Pull dependency context (spec fields + compact story handoff) for SpecKit input
  local dep_context="" dependency_bundle_json='[]'
  while IFS= read -r dep_id; do
    [ -z "$dep_id" ] && continue
    local dep_raw_path dep_abs_path dep_title dep_scope dep_invariants dep_files dep_note dep_entry
    dep_raw_path="$(jq -r --arg d "$dep_id" '.stories[] | select(.id == $d) | .story_path // ""' "$STORIES_FILE" 2>/dev/null || true)"
    [ -n "$dep_raw_path" ] || continue
    [[ "$dep_raw_path" != /* ]] && dep_abs_path="$WORKSPACE_ROOT/$dep_raw_path" || dep_abs_path="$dep_raw_path"
    [ -f "$dep_abs_path" ] || continue
    dep_title="$(jq -r '.title // ""' "$dep_abs_path" 2>/dev/null || true)"
    dep_scope="$(jq -r '.spec.scope // ""' "$dep_abs_path" 2>/dev/null || true)"
    dep_invariants="$(jq -r '(.spec.preserved_invariants // []) | join("; ")' "$dep_abs_path" 2>/dev/null || true)"
    dep_files="$(jq -r 'if (.story_handoff // null) != null then ((.story_handoff.files_touched // []) | join(", ")) else ([.tasks[].scope[]?] | unique | join(", ")) end' "$dep_abs_path" 2>/dev/null || true)"
    dep_files="$(sanitize_dep_file_list "$dep_files")"
    dep_note="$(jq -r '
      if (.story_handoff // null) != null then
        "Contracts added: " + ((.story_handoff.contracts_added // []) | join(", ")) + "\n" +
        "Residual risks: " + ((.story_handoff.residual_risks // []) | join("; "))
      else
        ""
      end
    ' "$dep_abs_path" 2>/dev/null || true)"
    dep_entry=""
    dep_scope="$(compact_text "$dep_scope" 180)"
    dep_files="$(compact_list "$dep_files" 4)"
    dep_invariants="$(compact_text "$dep_invariants" 180)"
    dep_note="$(compact_text "$dep_note" 160)"
    if [ -n "$dep_scope" ]; then dep_entry="${dep_entry}  Scope: $dep_scope"$'\n'; fi
    if [ -n "$dep_files" ]; then dep_entry="${dep_entry}  Files: $dep_files"$'\n'; fi
    if [ -n "$dep_invariants" ]; then dep_entry="${dep_entry}  Invariants: $dep_invariants"$'\n'; fi
    if [ -n "$dep_note" ]; then dep_entry="${dep_entry}  Notes: $dep_note"$'\n'; fi
    [ -n "$dep_entry" ] || continue
    dependency_bundle_json="$(
      jq -nc \
        --arg id "$dep_id" \
        --arg title "$dep_title" \
        --arg scope "$dep_scope" \
        --arg files "$dep_files" \
        --arg invariants "$dep_invariants" \
        --arg notes "$dep_note" \
        --argjson current "$dependency_bundle_json" \
        '$current + [{
          storyId: $id,
          title: $title,
          scope: $scope,
          files: ($files | split(", ") | map(select(length > 0 and . != "..."))),
          invariants: $invariants,
          notes: $notes
        }]'
    )"
    dep_context="${dep_context}
Prior story $dep_id ($dep_title):
$dep_entry"
  done < <(printf '%s' "$story_meta" | jq -r '.depends_on[]?' 2>/dev/null)

  local command_map_json prep_context_path
  command_map_json="$(build_project_command_map_json "$WORKSPACE_ROOT")"
  prep_context_path="$(story_prep_context_path "$story_dir")"
  local prep_fingerprint existing_fingerprint
  prep_fingerprint="$(compute_story_prep_fingerprint \
    "$story_id" \
    "$sprint" \
    "$title" \
    "$goal" \
    "$prompt_context" \
    "$repo_briefing_abs" \
    "$command_map_json" \
    "$depends_on_arr" \
    "$story_focus_hints" \
    "$dep_context")"
  existing_fingerprint="$(read_story_prep_fingerprint "$prep_context_path")"

  if [ "$dry_run" -eq 1 ]; then
    echo "=== DRY RUN: specify for $story_id ==="
    echo "Binary:      $specify_bin"
    echo "Specify dir: $specify_dir"
    echo "Title:       $title"
    echo "Goal:        $goal"
    echo "Fingerprint: $prep_fingerprint"
    return 0
  fi

  local stage_started_at stage_duration_ms
  stage_started_at="$(epoch_seconds)"

  # Short-circuit if artifacts already exist and prep inputs are unchanged
  if specify_artifacts_complete "$specify_dir" && [ "$force" -eq 0 ] && [ -n "$existing_fingerprint" ] && [ "$existing_fingerprint" = "$prep_fingerprint" ]; then
    if [ ! -f "$(story_prep_bundle_context_path "$story_dir")" ] || [ ! -f "$(story_prep_bundle_commands_path "$story_dir")" ] || [ ! -f "$(story_prep_bundle_dependencies_path "$story_dir")" ] || [ ! -f "$(story_prep_bundle_schema_path "$story_dir")" ]; then
      write_story_prep_bundle \
        "$story_dir" \
        "$story_id" \
        "$sprint" \
        "$title" \
        "$goal" \
        "$prompt_context" \
        "$repo_briefing_rel" \
        "$command_map_json" \
        "$depends_on_arr" \
        "$(focus_hints_to_json "$story_focus_hints")" \
        "$(jq -c '.dependencyStories // []' "$prep_context_path" 2>/dev/null || printf '[]')" \
        "$prep_fingerprint"
    fi
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
        'null'
    fi
    echo "SpecKit artifacts up to date for $story_id (fingerprint match)"
    prep_record_stage "$story_id" "specify" "skipped" "Artifacts up to date (fingerprint match)" "$(jq -nc --arg dir "$specify_dir" --arg prep "$prep_context_path" '[$dir, $prep]')" 0
    if [ "$no_generate" -eq 0 ]; then
      if [ ! -f "$story_path_abs" ]; then
        local gen_args=()
        [ "$dry_run" -eq 1 ] && gen_args+=(--dry-run)
        cmd_generate "$story_id" "${gen_args[@]}"
      else
        if [ "$(read_story_generate_fingerprint "$prep_context_path")" = "$prep_fingerprint" ]; then
          echo "story.json up to date for $story_id (prep fingerprint match)"
          prep_record_stage "$story_id" "generate" "skipped" "story.json up to date (prep fingerprint match)" "$(jq -nc --arg path "$raw_path" --arg prep "$prep_context_path" '[$path, $prep]')" 0
        else
          echo "story.json already exists for $story_id — skipping generate."
        fi
      fi
    fi
    prep_finalize_if_mode "specify" "passed"
    return 0
  fi

  # Clear existing artifacts when --force is set
  if [ "$force" -eq 1 ] && [ -d "$specify_dir" ]; then
    rm -rf "$specify_dir"
    echo "Cleared existing SpecKit artifacts for $story_id"
  fi

  mkdir -p "$specify_dir"
  write_story_prep_context \
    "$prep_context_path" \
    "$story_id" \
    "$sprint" \
    "$title" \
    "$goal" \
    "$prompt_context" \
    "$repo_briefing_rel" \
    "$command_map_json" \
    "$depends_on_arr" \
    "$story_focus_hints" \
    "$dep_context" \
    "$prep_fingerprint" \
    "$dependency_bundle_json"
  write_story_prep_bundle \
    "$story_dir" \
    "$story_id" \
    "$sprint" \
    "$title" \
    "$goal" \
    "$prompt_context" \
    "$repo_briefing_rel" \
    "$command_map_json" \
    "$depends_on_arr" \
    "$(focus_hints_to_json "$story_focus_hints")" \
    "$dependency_bundle_json" \
    "$prep_fingerprint"

  # Write SpecKit feature input file
  cat > "$specify_dir/input.md" <<SPECIN
# Feature: $title

## What to Build
$goal

## Context and Constraints
$prompt_context

## Story Metadata
- Story ID: $story_id
- Sprint: $sprint
- Priority: $priority
- Effort (story points): $effort
- Depends on: $depends_on_arr

## Repo Briefing
- Start with: $repo_briefing_rel

## Compact Story Capsule
- Start with: $(story_prep_bundle_capsule_path "$story_dir")

## Resolved Verification Commands
$(format_command_map_for_prompt "$command_map_json")
SPECIN

  if [ -n "$dep_context" ]; then
    printf '\n## Prior Story Results\n%s\n' "$dep_context" >> "$specify_dir/input.md"
  fi

  if [ -n "$story_focus_files_json" ] && [ "$story_focus_files_json" != "[]" ]; then
    printf '\n## Likely Implementation Files\n%s\n' "$(focus_hints_to_markdown "$story_focus_hints")" >> "$specify_dir/input.md"
  fi

  local word_count
  word_count=$(wc -w < "$specify_dir/input.md")
  if [ "$word_count" -lt 30 ]; then
    echo "WARN: input.md is thin ($word_count words) — consider adding more detail to story goal and promptContext."
  fi

  # Trim dep_context to avoid unbounded prep bundle growth
  local trimmed_dep_context="$dep_context"
  if [ "${#trimmed_dep_context}" -gt 1800 ]; then
    trimmed_dep_context="$(printf '%s' "$trimmed_dep_context" | head -c 1800)"
    trimmed_dep_context="$trimmed_dep_context"$'\n... (truncated)'
  fi

  local speckit_prompt
  speckit_prompt="$(cat <<SKPROMPT
Run the SpecKit workflow for this story and complete all three phases without pausing.

Feature input file: $specify_dir/input.md
Repo briefing file: $repo_briefing_rel
Story capsule: $(story_prep_bundle_capsule_path "$story_dir")
Prep bundle context: $(story_prep_bundle_context_path "$story_dir")
Prep bundle dependencies: $(story_prep_bundle_dependencies_path "$story_dir")
Prep bundle commands: $(story_prep_bundle_commands_path "$story_dir")

Use the story capsule, repo briefing, input.md, and prep bundle as the primary context.
Do not read Ralph framework files such as scripts/ralph/README-local.md, scripts/ralph/doctor.sh, or scripts/ralph/lib/specify.sh unless the prep bundle is missing a required fact.
Do not reread package.json, jest.config.ts, or tsconfig.json when the repo briefing and prep bundle already provide the needed commands, aliases, or project shape. Only inspect them when this story needs exact config semantics.
Do not inspect node_modules, bundled framework docs, or generated framework documentation unless local source files and config still leave a required framework rule ambiguous.
Keep any extra file inspection tightly scoped to the likely implementation area, nearest tests, and directly relevant config.
Do not narrate your plan, summarize your work, or restate constraints.

Phase 1 — Specify:
Write output to: $specify_dir/spec.md

Phase 2 — Plan:
Write output to: $specify_dir/plan.md

Phase 3 — Tasks:
Write output to: $specify_dir/tasks.md

All three files must be written before finishing. Avoid repeated repo summaries. Do not commit.
SKPROMPT
)"

  echo "Running SpecKit analysis for $story_id (phases: specify → plan → tasks)..."
  story_harness_profile_push "$story_meta"
  local prep_execution_profile_json="${STORY_EXECUTION_PROFILE_JSON:-null}"
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
  prep_record_stage "$story_id" "specify" "running" "Running SpecKit workflow" "$(jq -nc --arg dir "$specify_dir" --arg prep "$prep_context_path" '[$dir, $prep]')" 0 "$prep_execution_profile_json"
  prep_heartbeat_start "specify:$story_id"
  if ! harness_exec_prompt "$speckit_prompt" "$WORKSPACE_ROOT"; then
    prep_heartbeat_stop
    story_harness_profile_pop
    prep_fail_stage_and_exit "specify" "$story_id" "specify" "SpecKit analysis failed for $story_id" "$(jq -nc --arg dir "$specify_dir" --arg prep "$prep_context_path" '[$dir, $prep]')" "$prep_execution_profile_json"
  fi
  prep_heartbeat_stop
  story_harness_profile_pop

  # Validate artifacts
  local missing=0
  for artifact in spec.md plan.md tasks.md; do
    [ -f "$specify_dir/$artifact" ] || { echo "WARN: SpecKit did not produce $artifact"; missing=$((missing + 1)); }
  done

  if [ "$missing" -gt 0 ]; then
    prep_fail_stage_and_exit "specify" "$story_id" "specify" "SpecKit did not produce all required artifacts ($missing missing). Check the Codex session log and re-run with --force." "$(jq -nc --arg dir "$specify_dir" --arg prep "$prep_context_path" '[$dir, $prep]')" "$prep_execution_profile_json"
  fi

  stage_duration_ms="$(( ($(epoch_seconds) - stage_started_at) * 1000 ))"
  prep_record_stage "$story_id" "specify" "passed" "SpecKit artifacts created" "$(jq -nc --arg spec "$specify_dir/spec.md" --arg plan "$specify_dir/plan.md" --arg tasks "$specify_dir/tasks.md" --arg prep "$prep_context_path" '[$spec, $plan, $tasks, $prep]')" "$stage_duration_ms" "$prep_execution_profile_json"
  prep_finalize_if_mode "specify" "passed"
  echo "SpecKit artifacts written: $specify_dir/{spec.md,plan.md,tasks.md}"

  if [ "$no_generate" -eq 0 ]; then
    local gen_args=()
    [ "$force" -eq 1 ] && gen_args+=(--force)
    cmd_generate "$story_id" "${gen_args[@]}"
  fi
}
