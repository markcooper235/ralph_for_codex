#!/bin/bash
# Backlog authoring commands for adding and importing story containers.
#
# Lazy-loaded by ralph-story.sh. The host provides backlog/path validation
# helpers and the STORIES_FILE and WORKSPACE_ROOT variables.

cmd_add() {
  resolve_stories_file

  local new_title=""
  local new_id=""
  local new_priority=""
  local new_effort=3
  local new_status="planned"
  local new_agent=""
  local -a new_depends=()
  local new_goal=""
  local new_prompt_context=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)             new_id="${2:-}"; shift 2 ;;
      --title)          new_title="${2:-}"; shift 2 ;;
      --priority)       new_priority="${2:-}"; shift 2 ;;
      --effort)         new_effort="${2:-3}"; shift 2 ;;
      --status)         new_status="${2:-planned}"; shift 2 ;;
      --agent)          new_agent="${2:-}"; shift 2 ;;
      --depends-on)     new_depends+=("${2:-}"); shift 2 ;;
      --goal)           new_goal="${2:-}"; shift 2 ;;
      --prompt-context) new_prompt_context="${2:-}"; shift 2 ;;
      *) fail "Unknown add option: $1" ;;
    esac
  done

  [ -n "$new_title" ] || fail "--title is required"

  # Auto-assign ID
  if [ -z "$new_id" ]; then
    local max_n=0
    while IFS= read -r existing_id; do
      n="${existing_id#S-}"
      n="${n#0}"
      [ "$n" -gt "$max_n" ] 2>/dev/null && max_n="$n"
    done < <(jq -r '.stories[].id' "$STORIES_FILE")
    new_id="$(printf 'S-%03d' $((max_n + 1)))"
  fi

  # Auto-assign priority
  if [ -z "$new_priority" ]; then
    new_priority="$(jq '[.stories[].priority] | max + 1' "$STORIES_FILE")"
  fi

  # Build depends_on array
  local deps_json
  deps_json="$(parse_depends_on_args "$new_id" ${new_depends[@]+"${new_depends[@]}"})"

  # Determine active sprint for story_path
  local active_sprint
  active_sprint="$(get_active_sprint)" || fail "No active sprint."
  local sprint_dir_rel
  sprint_dir_rel="$(dirname "$(sprint_stories_file "$active_sprint")")"
  sprint_dir_rel="${sprint_dir_rel#${WORKSPACE_ROOT}/}"
  local story_path="$sprint_dir_rel/stories/$new_id/story.json"

  local tmp
  tmp="$(mktemp)"
  jq \
    --arg id "$new_id" \
    --arg title "$new_title" \
    --arg sprint "$active_sprint" \
    --argjson priority "$new_priority" \
    --argjson effort "$new_effort" \
    --arg status "$new_status" \
    --arg agent "$new_agent" \
    --argjson depends "$deps_json" \
    --arg goal "$new_goal" \
    --arg ctx "$new_prompt_context" \
    --arg path "$story_path" \
    '.stories += [{
      "id": $id,
      "title": $title,
      "priority": $priority,
      "effort": $effort,
      "planningSource": "local",
      "status": $status,
      "agent": $agent,
      "sprint": $sprint,
      "depends_on": $depends,
      "story_path": $path,
      "goal": $goal,
      "promptContext": $ctx
    }]' \
    "$STORIES_FILE" > "$tmp"
  mv "$tmp" "$STORIES_FILE"

  echo "Added story: $new_id — $new_title"
}

cmd_import_story() {
  local story_id="${1:-}"
  local source_path="${2:-}"
  [ -n "$story_id" ] && [ -n "$source_path" ] || fail "Usage: ralph-story.sh import-story <ID> <PATH|-> [--force]"
  shift 2 || true
  local force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1; shift ;;
      *) fail "Unknown import-story option: $1" ;;
    esac
  done

  resolve_stories_file
  story_exists_in_backlog "$story_id" || fail "Story $story_id not found in $STORIES_FILE"

  local story_meta raw_path story_path_abs sprint expected_path tmp_input
  story_meta="$(jq -r --arg id "$story_id" '.stories[] | select(.id == $id)' "$STORIES_FILE")"
  raw_path="$(printf '%s' "$story_meta" | jq -r '.story_path // empty')"
  sprint="$(printf '%s' "$story_meta" | jq -r '.sprint // empty')"
  [ -n "$sprint" ] || sprint="$(jq -r '.sprint // empty' "$STORIES_FILE")"
  [ -n "$raw_path" ] || fail "story_path not set for $story_id"
  [ -n "$sprint" ] || fail "sprint not set for $story_id"
  story_path_abs="$(resolve_repo_relative_path "$raw_path")"

  if [ -f "$story_path_abs" ] && [ "$force" -ne 1 ]; then
    fail "story.json already exists: $story_path_abs (use --force to overwrite)"
  fi

  mkdir -p "$(dirname "$story_path_abs")"
  if [ "$source_path" = "-" ]; then
    tmp_input="$(mktemp)"
    cat > "$tmp_input"
    source_path="$tmp_input"
  fi
  [ -f "$source_path" ] || fail "Import source not found: $source_path"

  cp "$source_path" "$story_path_abs"
  normalize_story_container "$story_path_abs"
  validate_story_container_file "$story_path_abs" "$story_id" "$sprint"

  local imported_status imported_passes tmp
  imported_status="$(jq -r '.status // empty' "$story_path_abs")"
  imported_passes="$(jq -r '.passes // false' "$story_path_abs")"
  if [ -n "$imported_status" ]; then
    tmp="$(mktemp)"
    jq --arg id "$story_id" --arg status "$imported_status" --argjson passes "$imported_passes" '
      (.stories[] | select(.id == $id) | .status) = $status
      | (.stories[] | select(.id == $id) | .passes) = $passes
    ' "$STORIES_FILE" > "$tmp"
    mv "$tmp" "$STORIES_FILE"
  fi

  if [ -n "${tmp_input:-}" ] && [ -f "$tmp_input" ]; then
    rm -f "$tmp_input"
  fi

  echo "Imported story container for $story_id: $raw_path"
}

cmd_import_prd() {
  resolve_stories_file

  local prd_path="${1:-}"
  [ -n "$prd_path" ] || prd_path="$SCRIPT_DIR/prd.json"
  [ -f "$prd_path" ] || fail "PRD file not found: $prd_path"

  jq -e '.userStories | length > 0' "$prd_path" >/dev/null 2>&1 || \
    fail "No userStories[] found in $prd_path"

  local active_sprint
  active_sprint="$(get_active_sprint)" || fail "No active sprint."

  local imported=0 skipped=0

  while IFS= read -r us_json; do
    local us_id us_title us_desc us_ac us_priority us_passes
    us_id="$(printf '%s' "$us_json" | jq -r '.id')"
    us_title="$(printf '%s' "$us_json" | jq -r '.title // ""')"
    us_desc="$(printf '%s' "$us_json" | jq -r '.description // ""')"
    us_ac="$(printf '%s' "$us_json" | jq -r '(.acceptanceCriteria // []) | join(". ")')"
    us_priority="$(printf '%s' "$us_json" | jq -r '.priority // 99')"
    us_passes="$(printf '%s' "$us_json" | jq -r '.passes // false')"

    if [ "$us_passes" = "true" ]; then
      echo "SKIP $us_id (passes=true): $us_title"
      skipped=$((skipped + 1))
      continue
    fi

    # Auto-assign next S-NNN from current max
    local max_n=0
    while IFS= read -r existing_id; do
      local raw_n="${existing_id#S-}"
      if [[ "$raw_n" =~ ^[0-9]+$ ]]; then
        local n=$(( 10#$raw_n ))
        [ "$n" -gt "$max_n" ] && max_n="$n"
      fi
    done < <(jq -r '.stories[].id' "$STORIES_FILE")
    local new_id
    new_id="$(printf 'S-%03d' $((max_n + 1)))"
    local sprint_dir_rel
    sprint_dir_rel="$(dirname "$(sprint_stories_file "$active_sprint")")"
    sprint_dir_rel="${sprint_dir_rel#${WORKSPACE_ROOT}/}"
    local story_path="$sprint_dir_rel/stories/$new_id/story.json"

    local tmp
    tmp="$(mktemp)"
    jq \
      --arg id "$new_id" \
      --arg title "$us_title" \
      --argjson priority "$us_priority" \
      --arg status "planned" \
      --arg goal "$us_desc" \
      --arg ctx "$us_ac" \
      --arg path "$story_path" \
      '.stories += [{
        "id": $id,
        "title": $title,
        "priority": $priority,
        "effort": 3,
        "planningSource": "prd-import",
        "status": $status,
        "depends_on": [],
        "story_path": $path,
        "goal": $goal,
        "promptContext": $ctx
      }]' \
      "$STORIES_FILE" > "$tmp"
    mv "$tmp" "$STORIES_FILE"

    echo "Imported $us_id → $new_id: $us_title"
    imported=$((imported + 1))
  done < <(jq -c '.userStories[]' "$prd_path")

  echo ""
  echo "Imported: $imported  Skipped (done): $skipped"
  if [ "$imported" -gt 0 ]; then
    echo "Next: run './ralph-story.sh specify <ID>' for each story to run SpecKit analysis and create task containers."
  fi
}
