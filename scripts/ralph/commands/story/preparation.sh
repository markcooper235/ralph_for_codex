#!/bin/bash
# Batch story preparation and preparation-journal commands.
#
# Lazy-loaded by ralph-story.sh. The host supplies single-story specify and
# generate commands plus preparation journal helpers. prepare-all additionally
# loads the health module before invoking this module.

cmd_specify_all() {
  resolve_stories_file
  local force=0 jobs=2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1; shift ;;
      --jobs)  jobs="${2:-1}"; shift 2 ;;
      *) fail "Unknown specify-all option: $1" ;;
    esac
  done
  [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || fail "--jobs must be a positive integer"
  local sprint_name
  sprint_name="$(jq -r '.sprint // empty' "$STORIES_FILE")"
  require_story_sprint "$sprint_name" "specify-all"
  ensure_prep_run_dir "$sprint_name" "specify-all" >/dev/null
  RALPH_PREP_PHASE="specify-all"
  prep_touch_summary "specify-all" "" ""

  local force_flag=()
  [ "$force" -eq 1 ] && force_flag+=(--force)

  local pending=() skipped=0
  while IFS= read -r sid; do
    local raw_path story_path_abs specify_dir
    raw_path="$(jq -r --arg id "$sid" '.stories[] | select(.id == $id) | .story_path // ""' "$STORIES_FILE")"
    [[ "$raw_path" != /* ]] && story_path_abs="$WORKSPACE_ROOT/$raw_path" || story_path_abs="$raw_path"
    specify_dir="$(dirname "$story_path_abs")/.specify"
    if story_is_unrecovered_migration_placeholder "$story_path_abs"; then
      echo "SKIP $sid: migration placeholder (recover in generate phase)"
      prep_record_stage "$sid" "specify" "skipped" "Migration placeholder deferred to generate phase" "$(jq -nc --arg dir "$specify_dir" '[$dir]')" 0
      skipped=$((skipped + 1))
      continue
    fi
    if [ -f "$story_path_abs" ] && [ "$force" -eq 0 ]; then
      echo "SKIP $sid: story.json exists"
      prep_record_stage "$sid" "specify" "skipped" "story.json already exists" "$(jq -nc --arg path "$raw_path" '[$path]')" 0
      skipped=$((skipped + 1))
      continue
    fi
    pending+=("$sid")
  done < <(jq -r '.stories[] | select(.status != "done" and .status != "abandoned") | .id' "$STORIES_FILE")

  local count=0 failed=0 total="${#pending[@]}"
  if [ "$total" -eq 0 ]; then
    echo "specify-all: nothing to do ($skipped skipped)."; return 0
  fi

  local i=0
  while [ "$i" -lt "$total" ]; do
    local batch_end=$(( i + jobs ))
    [ "$batch_end" -gt "$total" ] && batch_end="$total"
    local batch=("${pending[@]:$i:$(( batch_end - i ))}")

    if [ "$jobs" -le 1 ]; then
      local sid="${batch[0]}"
      local logf
      logf="$(prep_stage_log_path "$sid" "specify")"
      echo "=== specify $sid ==="
      if cmd_specify "$sid" "${force_flag[@]+"${force_flag[@]}"}" > "$logf" 2>&1; then
        count=$((count + 1))
      else
        echo "WARN: specify failed for $sid"; failed=$((failed + 1))
      fi
      cat "$logf"
    else
      local pids=() logs=() sids=()
      for sid in "${batch[@]}"; do
        local logf; logf="$(prep_stage_log_path "$sid" "specify")"
        ( cmd_specify "$sid" "${force_flag[@]+"${force_flag[@]}"}" ) > "$logf" 2>&1 &
        pids+=($!); logs+=("$logf"); sids+=("$sid")
      done
      local j rc
      for j in "${!pids[@]}"; do
        wait "${pids[$j]}" && rc=0 || rc=$?
        echo "=== specify ${sids[$j]} ==="
        cat "${logs[$j]}"; rm -f "${logs[$j]}"
        [ "$rc" -eq 0 ] && count=$((count + 1)) \
          || { echo "WARN: specify failed for ${sids[$j]}"; failed=$((failed + 1)); }
      done
    fi
    i="$batch_end"
  done

  echo ""
  echo "specify-all: $count processed, $skipped skipped, $failed failed."
  [ "$failed" -eq 0 ] || return 1
}

cmd_generate_all() {
  resolve_stories_file
  local force=0 jobs=2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1; shift ;;
      --jobs)  jobs="${2:-1}"; shift 2 ;;
      *) fail "Unknown generate-all option: $1" ;;
    esac
  done
  [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || fail "--jobs must be a positive integer"
  local sprint_name
  sprint_name="$(jq -r '.sprint // empty' "$STORIES_FILE")"
  require_story_sprint "$sprint_name" "generate-all"
  ensure_prep_run_dir "$sprint_name" "generate-all" >/dev/null
  RALPH_PREP_PHASE="generate-all"
  prep_touch_summary "generate-all" "" ""

  local force_flag=()
  [ "$force" -eq 1 ] && force_flag+=(--force)

  local pending=() placeholder_pending=() skipped=0
  while IFS= read -r sid; do
    local raw_path story_path_abs specify_dir prep_context_path prep_fingerprint generate_fingerprint
    raw_path="$(jq -r --arg id "$sid" '.stories[] | select(.id == $id) | .story_path // ""' "$STORIES_FILE")"
    story_path_abs="$(resolve_repo_relative_path "$raw_path")"
    specify_dir="$(dirname "$story_path_abs")/.specify"
    prep_context_path="$(story_prep_context_path "$(dirname "$story_path_abs")")"
    prep_fingerprint="$(read_story_prep_fingerprint "$prep_context_path")"
    generate_fingerprint="$(read_story_generate_fingerprint "$prep_context_path")"

    if [ ! -f "$specify_dir/spec.md" ] && ! { [ "$force" -eq 1 ] && story_is_unrecovered_migration_placeholder "$story_path_abs"; }; then
      echo "SKIP $sid: no SpecKit artifacts (run specify-all first)"
      prep_record_stage "$sid" "generate" "skipped" "No SpecKit artifacts available" "$(jq -nc --arg dir "$specify_dir" '[$dir]')" 0
      skipped=$((skipped + 1))
      continue
    fi

    if [ -f "$story_path_abs" ] && [ "$force" -eq 0 ]; then
      if [ -n "$prep_fingerprint" ] && [ "$prep_fingerprint" = "$generate_fingerprint" ]; then
        echo "SKIP $sid: story.json up to date (prep fingerprint match)"
        prep_record_stage "$sid" "generate" "skipped" "story.json up to date (prep fingerprint match)" "$(jq -nc --arg path "$raw_path" --arg prep "$prep_context_path" '[$path, $prep]')" 0
      else
        echo "SKIP $sid: story.json exists (use --force to overwrite)"
        prep_record_stage "$sid" "generate" "skipped" "story.json already exists" "$(jq -nc --arg path "$raw_path" '[$path]')" 0
      fi
      skipped=$((skipped + 1))
      continue
    fi

    if [ "$force" -eq 1 ] && story_is_unrecovered_migration_placeholder "$story_path_abs"; then
      placeholder_pending+=("$sid")
    else
      pending+=("$sid")
    fi
  done < <(jq -r '.stories[] | select(.status != "done" and .status != "abandoned") | .id' "$STORIES_FILE")

  local count=0 failed=0 total=$(( ${#pending[@]} + ${#placeholder_pending[@]} ))
  if [ "$total" -eq 0 ]; then
    echo "generate-all: nothing to do ($skipped skipped)."
    return 0
  fi

  if [ "${#placeholder_pending[@]}" -gt 0 ]; then
    echo "generate-all: processing ${#placeholder_pending[@]} migration placeholder(s) serially to keep stories.json updates safe."
    local sid
    for sid in "${placeholder_pending[@]}"; do
      local logf
      logf="$(prep_stage_log_path "$sid" "generate")"
      echo "=== generate $sid ==="
      if cmd_generate "$sid" "${force_flag[@]+"${force_flag[@]}"}" > "$logf" 2>&1; then
        count=$((count + 1))
      else
        echo "WARN: generate failed for $sid"
        failed=$((failed + 1))
      fi
      cat "$logf"
    done
  fi

  total="${#pending[@]}"
  if [ "$total" -eq 0 ]; then
    echo ""
    echo "generate-all: $count generated, $skipped skipped, $failed failed."
    [ "$failed" -eq 0 ] || return 1
    return 0
  fi

  local i=0
  while [ "$i" -lt "$total" ]; do
    local batch_end=$(( i + jobs ))
    [ "$batch_end" -gt "$total" ] && batch_end="$total"
    local batch=("${pending[@]:$i:$(( batch_end - i ))}")

    if [ "$jobs" -le 1 ]; then
      local sid="${batch[0]}"
      local logf
      logf="$(prep_stage_log_path "$sid" "generate")"
      echo "=== generate $sid ==="
      if cmd_generate "$sid" "${force_flag[@]+"${force_flag[@]}"}" > "$logf" 2>&1; then
        count=$((count + 1))
      else
        echo "WARN: generate failed for $sid"
        failed=$((failed + 1))
      fi
      cat "$logf"
    else
      local pids=() logs=() sids=()
      for sid in "${batch[@]}"; do
        local logf
        logf="$(prep_stage_log_path "$sid" "generate")"
        ( cmd_generate "$sid" "${force_flag[@]+"${force_flag[@]}"}" ) > "$logf" 2>&1 &
        pids+=($!)
        logs+=("$logf")
        sids+=("$sid")
      done
      local j=0
      for pid in "${pids[@]}"; do
        local sid="${sids[$j]}" logf="${logs[$j]}"
        echo "=== generate ${sid} ==="
        if wait "$pid"; then
          count=$((count + 1))
        else
          echo "WARN: generate failed for ${sid}"
          failed=$((failed + 1))
        fi
        cat "$logf"
        rm -f "$logf"
        j=$((j + 1))
      done
    fi

    i="$batch_end"
  done

  echo ""
  echo "generate-all: $count generated, $skipped skipped, $failed failed."
  [ "$failed" -eq 0 ] || return 1
}

cmd_prepare_all() {
  local force_flag=() jobs=2 requested_sprint=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force_flag+=(--force); shift ;;
      --jobs)  jobs="${2:-1}"; shift 2 ;;
      --sprint)
        requested_sprint="${2:-}"
        [ -n "$requested_sprint" ] || fail "Missing value for --sprint"
        shift 2
        ;;
      *) fail "Unknown prepare-all option: $1" ;;
    esac
  done

  if [ -n "$requested_sprint" ]; then
    resolve_stories_file_for_sprint "$requested_sprint"
  else
    resolve_stories_file
  fi
  local sprint_name
  sprint_name="$(jq -r '.sprint // empty' "$STORIES_FILE")"
  require_story_sprint "$sprint_name" "prepare-all"
  ensure_prep_run_dir "$sprint_name" "prepare-all" >/dev/null
  RALPH_PREP_PHASE="prepare-all"
  prep_touch_summary "prepare-all" "" ""

  local specify_failed=0 generate_failed=0
  echo "=== prepare-all: specify ==="
  prep_touch_summary "specify-all" "" ""
  if ! cmd_specify_all "${force_flag[@]+"${force_flag[@]}"}" --jobs "$jobs"; then
    specify_failed=1
  fi
  echo ""
  echo "=== prepare-all: generate ==="
  prep_touch_summary "generate-all" "" ""
  if ! cmd_generate_all "${force_flag[@]+"${force_flag[@]}"}" --jobs "$jobs"; then
    generate_failed=1
  fi
  echo ""
  echo "=== prepare-all: health ==="
  prep_touch_summary "health" "" ""
  local ready_candidates=0 health_failed=0
  while IFS= read -r sid; do
    local raw_path story_path_abs
    raw_path="$(jq -r --arg id "$sid" '.stories[] | select(.id == $id) | .story_path // ""' "$STORIES_FILE")"
    [[ "$raw_path" != /* ]] && story_path_abs="$WORKSPACE_ROOT/$raw_path" || story_path_abs="$raw_path"

    if _health_story "$sid"; then
      # Count planned stories that are healthy and structurally ready for mark-ready.
      local cur_status
      cur_status="$(jq -r --arg id "$sid" '.stories[] | select(.id == $id) | .status' "$STORIES_FILE")"
      if [ "$cur_status" = "planned" ] && [ -f "$story_path_abs" ] \
          && jq -e '.tasks | length > 0' "$story_path_abs" >/dev/null 2>&1; then
        ready_candidates=$((ready_candidates + 1))
      fi
    else
      health_failed=$((health_failed + 1))
    fi
  done < <(jq -r '.stories[] | select(.status != "done" and .status != "abandoned") | .id' "$STORIES_FILE")

  echo ""
  [ "$ready_candidates" -gt 0 ] && echo "$ready_candidates story/stories passed prep health and are ready candidates for ./ralph-sprint.sh mark-ready."
  [ "$health_failed" -gt 0 ] && echo "WARN: $health_failed story/stories have health issues — fix before mark-ready."
  [ "$ready_candidates" -gt 0 ] && [ "$health_failed" -eq 0 ] && echo "Next step: ./ralph-sprint.sh mark-ready $sprint_name"

  local final_status="passed"
  if [ "$specify_failed" -ne 0 ] || [ "$generate_failed" -ne 0 ] || [ "$health_failed" -ne 0 ]; then
    final_status="failed"
  fi
  prep_finalize_summary "$final_status"
  echo "Prep summary: $(prep_summary_path)"
  [ "$final_status" = "passed" ] || return 1
}

cmd_prep_status() {
  resolve_stories_file
  local sprint_name
  sprint_name="$(jq -r '.sprint // empty' "$STORIES_FILE")"

  local requested_sprint="" story_id="" details=0 story_limit=5
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sprint)
        requested_sprint="${2:-}"
        [ -n "$requested_sprint" ] || fail "Missing value for --sprint"
        shift 2
        ;;
      --story)
        story_id="${2:-}"
        [ -n "$story_id" ] || fail "Missing value for --story"
        shift 2
        ;;
      --details)
        details=1
        shift
        ;;
      --story-limit)
        story_limit="${2:-}"
        [ -n "$story_limit" ] || fail "Missing value for --story-limit"
        [[ "$story_limit" =~ ^[1-9][0-9]*$ ]] || fail "--story-limit must be a positive integer"
        shift 2
        ;;
      *)
        fail "Unknown prep-status option: $1"
        ;;
    esac
  done

  [ -n "$requested_sprint" ] && sprint_name="$requested_sprint"
  require_story_sprint "$sprint_name" "prep-status"

  local summary_path
  summary_path="$(latest_prep_summary_for_sprint "$sprint_name" || true)"
  [ -n "$summary_path" ] && [ -f "$summary_path" ] || fail "No prep run journal found for sprint '$sprint_name'."

  local mode status started_at finished_at story_count passed_count failed_count skipped_count running_count total_duration_ms
  mode="$(jq -r '.mode // "prep"' "$summary_path" 2>/dev/null || echo "prep")"
  status="$(jq -r '.status // "running"' "$summary_path" 2>/dev/null || echo "running")"
  started_at="$(jq -r '.started_at // ""' "$summary_path" 2>/dev/null || true)"
  finished_at="$(jq -r '.finished_at // ""' "$summary_path" 2>/dev/null || true)"
  story_count="$(jq -r '(.stories // {}) | length' "$summary_path" 2>/dev/null || echo 0)"
  passed_count="$(jq -r '.metrics.passed_stages // 0' "$summary_path" 2>/dev/null || echo 0)"
  failed_count="$(jq -r '.metrics.failed_stages // 0' "$summary_path" 2>/dev/null || echo 0)"
  skipped_count="$(jq -r '.metrics.skipped_stages // 0' "$summary_path" 2>/dev/null || echo 0)"
  running_count="$(jq -r '.metrics.running_stages // 0' "$summary_path" 2>/dev/null || echo 0)"
  total_duration_ms="$(jq -r '.metrics.total_duration_ms // 0' "$summary_path" 2>/dev/null || echo 0)"

  echo "Prep sprint: $sprint_name"
  echo "Prep mode: $mode"
  echo "Prep status: $status"
  [ -n "$started_at" ] && echo "Prep started: $started_at"
  [ -n "$finished_at" ] && echo "Prep finished: $finished_at"
  echo "Prep stories: $story_count"
  echo "Prep metrics: passed=$passed_count failed=$failed_count skipped=$skipped_count running=$running_count duration-ms=$total_duration_ms"
  echo "Prep journal: $summary_path"

  local story_filter_json='null'
  if [ -n "$story_id" ]; then
    story_filter_json="$(jq -nc --arg story "$story_id" '$story')"
  fi

  jq -r \
    --argjson limit "$story_limit" \
    --argjson details "$details" \
    --argjson story_filter "$story_filter_json" '
    def selected_stories:
      (.stories // {})
      | to_entries
      | sort_by(.key)
      | if $story_filter == null then . else map(select(.key == $story_filter)) end
      | .[:$limit];
    selected_stories[]
    | .key as $story_id
    | .value as $stages
    | ($stages | to_entries | sort_by(.key) | map("\(.key)=\(.value.status // "unknown")") | join(", ")) as $compact
    | "Prep story " + $story_id + ": " + (if $compact == "" then "(no stages recorded)" else $compact end),
      (if $details == 1 then
         ($stages
          | to_entries
          | sort_by(.key)
          | .[]
          | "Prep detail " + $story_id + " " + .key + ": "
            + (.value.status // "unknown")
            + (if (.value.detail // "") == "" then "" else " - " + .value.detail end)
            + " (duration-ms=" + ((.value.duration_ms // 0) | tostring) + ", updated=" + (.value.updated_at // "unknown") + ")")
       else empty end)
  ' "$summary_path"
}

