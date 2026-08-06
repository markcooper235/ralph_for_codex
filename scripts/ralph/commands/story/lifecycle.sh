#!/bin/bash
# Story lifecycle commands.
#
# This module is lazy-loaded by ralph-story.sh. Sourcing it must not perform
# work. Its commands use the host's fail, resolve_stories_file,
# resolve_story_path, and branch helper functions plus the STORIES_FILE and
# WORKSPACE_ROOT variables.

cmd_list() {
  resolve_stories_file
  local sprint active_id marker
  sprint="$(jq -r '.sprint' "$STORIES_FILE")"
  active_id="$(jq -r '.activeStoryId // "none"' "$STORIES_FILE")"

  echo "Sprint: $sprint   active=$active_id"
  echo ""
  printf "%-10s %-6s %-6s %-12s %s\n" "ID" "PRI" "EFF" "STATUS" "TITLE"
  printf "%-10s %-6s %-6s %-12s %s\n" "----------" "------" "------" "------------" "-----"
  jq -r '.stories | sort_by(.priority) | .[] | [.id, (.priority|tostring), (.effort|tostring), .status, .title] | @tsv' "$STORIES_FILE" |
    while IFS=$'\t' read -r sid pri eff status title; do
      marker="  "
      [ "$sid" = "$active_id" ] && marker="->"
      printf "%s %-8s %-6s %-6s %-12s %s\n" "$marker" "$sid" "$pri" "$eff" "$status" "$title"
    done
}

cmd_show() {
  local story_id="${1:-}" story_path
  [ -n "$story_id" ] || fail "Usage: ralph-story.sh show <ID>"
  resolve_stories_file
  story_path="$(resolve_story_path "$story_id")"
  [ -f "$story_path" ] || fail "story.json not found at: $story_path"
  jq '.' "$story_path"
}

cmd_next_id() {
  resolve_stories_file

  if command -v node >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/core/cli/next-id.mjs" ]; then
    node "$SCRIPT_DIR/core/cli/next-id.mjs" "$STORIES_FILE"
    return $?
  fi

  # Compatibility fallback for installations without Node.js.
  jq -r '.stories | map(select(.status == "ready" or .status == "planned")) | sort_by([.priority, .id]) | .[] | .id' "$STORIES_FILE" |
    while IFS= read -r sid; do
      local deps_ok=true dep dep_status
      while IFS= read -r dep; do
        [ -z "$dep" ] && continue
        dep_status="$(jq -r --arg d "$dep" '.stories[] | select(.id == $d) | .status' "$STORIES_FILE")"
        [ -z "$dep_status" ] && continue
        if [ "$dep_status" != "done" ]; then
          deps_ok=false
          break
        fi
      done < <(jq -r --arg id "$sid" '.stories[] | select(.id == $id) | .depends_on[]?' "$STORIES_FILE")
      if [ "$deps_ok" = "true" ]; then
        echo "$sid"
        return 0
      fi
    done
}

cmd_next() {
  resolve_stories_file
  local next_id
  next_id="$(cmd_next_id)"
  [ -n "$next_id" ] || { echo "No eligible story found."; return 0; }
  jq --arg id "$next_id" '.stories[] | select(.id == $id)' "$STORIES_FILE"
}

cmd_use() {
  local story_id="${1:-}" exists story_path tmp
  [ -n "$story_id" ] || fail "Usage: ralph-story.sh use <ID>"
  resolve_stories_file
  exists="$(jq -r --arg id "$story_id" '.stories[] | select(.id == $id) | .id' "$STORIES_FILE")"
  [ -n "$exists" ] || fail "Story $story_id not found."
  story_path="$(resolve_story_path "$story_id")"
  [ -f "$story_path" ] || fail "story.json not found for $story_id: $story_path
  Run: ./ralph-story.sh generate $story_id"
  tmp="$(mktemp)"
  jq --arg id "$story_id" '.activeStoryId = $id' "$STORIES_FILE" > "$tmp"
  mv "$tmp" "$STORIES_FILE"
  echo "Active story set to: $story_id"
}

cmd_start_next() {
  resolve_stories_file
  local next_id story_path tmp started_id story_branch active_sprint sprint_branch
  next_id="$(cmd_next_id)"
  [ -n "$next_id" ] || fail "No eligible story to start."
  story_path="$(resolve_story_path "$next_id")"
  [ -f "$story_path" ] || fail "story.json not found for $next_id: $story_path
  Run: ./ralph-story.sh generate $next_id"
  if command -v node >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/core/cli/start-next.mjs" ]; then
    started_id="$(node "$SCRIPT_DIR/core/cli/start-next.mjs" "$STORIES_FILE")" || return $?
    [ "$started_id" = "$next_id" ] || fail "Started story mismatch: expected $next_id, got $started_id"
  else
    tmp="$(mktemp)"
    jq --arg id "$next_id" '(.stories[] | select(.id == $id) | .status) = "active" | .activeStoryId = $id' "$STORIES_FILE" > "$tmp"
    mv "$tmp" "$STORIES_FILE"
  fi
  echo "Started story: $next_id"

  git -C "$WORKSPACE_ROOT" add "$STORIES_FILE" 2>/dev/null || true
  if ! git -C "$WORKSPACE_ROOT" diff --cached --quiet 2>/dev/null; then
    git -C "$WORKSPACE_ROOT" commit -m "chore(ralph): start $next_id"
  fi

  story_branch="$(jq -r '.branchName // ""' "$story_path" 2>/dev/null || true)"
  if [ -n "$story_branch" ]; then
    active_sprint="$(get_active_sprint 2>/dev/null || echo "")"
    sprint_branch=""
    [ -n "$active_sprint" ] && sprint_branch="ralph/sprint/$active_sprint"
    if command -v node >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/core/cli/ensure-story-branch.mjs" ]; then
      node "$SCRIPT_DIR/core/cli/ensure-story-branch.mjs" "$WORKSPACE_ROOT" "$story_branch" "$sprint_branch" || return $?
    else
      if git -C "$WORKSPACE_ROOT" show-ref --verify --quiet "refs/heads/$story_branch" 2>/dev/null; then
        git -C "$WORKSPACE_ROOT" checkout "$story_branch"
        if [ -n "$sprint_branch" ] && [ -z "$(branch_parent_from_upstream "$story_branch")" ]; then
          set_branch_parent "$story_branch" "$sprint_branch"
        fi
        echo "Checked out story branch: $story_branch"
      elif [ -n "$sprint_branch" ] && git -C "$WORKSPACE_ROOT" show-ref --verify --quiet "refs/heads/$sprint_branch" 2>/dev/null; then
        git -C "$WORKSPACE_ROOT" checkout -b "$story_branch" "$sprint_branch"
        set_branch_parent "$story_branch" "$sprint_branch"
        echo "Created story branch: $story_branch (from $sprint_branch)"
      else
        git -C "$WORKSPACE_ROOT" checkout -b "$story_branch"
        echo "Created story branch: $story_branch (from current HEAD)"
      fi
    fi
  fi

  while IFS= read -r dep_id; do
    [ -z "$dep_id" ] && continue
    local dep_raw dep_abs dep_note
    dep_raw="$(jq -r --arg d "$dep_id" '.stories[] | select(.id == $d) | .story_path // ""' "$STORIES_FILE" 2>/dev/null || true)"
    [ -n "$dep_raw" ] || continue
    [[ "$dep_raw" != /* ]] && dep_abs="$WORKSPACE_ROOT/$dep_raw" || dep_abs="$dep_raw"
    [ -f "$dep_abs" ] || continue
    dep_note="$(jq -r 'if (.story_handoff // null) != null then (((.story_handoff.files_touched // []) | join(", ")) + " | " + ((.story_handoff.contracts_added // []) | join(", "))) else "" end' "$dep_abs" 2>/dev/null || true)"
    [ -n "$dep_note" ] || echo "WARN: Dependency $dep_id has no story_handoff — downstream context for this story will be thin."
  done < <(jq -r --arg id "$next_id" '.stories[] | select(.id == $id) | .depends_on[]?' "$STORIES_FILE" 2>/dev/null || true)
}

cmd_tasks() {
  local story_id="${1:-}" story_path
  [ -n "$story_id" ] || fail "Usage: ralph-story.sh tasks <ID>"
  resolve_stories_file
  story_path="$(resolve_story_path "$story_id")"
  [ -f "$story_path" ] || fail "story.json not found at: $story_path"
  echo "Tasks for story $story_id:"
  echo ""
  printf "%-8s %-8s %s\n" "ID" "STATUS" "TITLE"
  printf "%-8s %-8s %s\n" "--------" "--------" "-----"
  jq -r '.tasks[] | [.id, .status, .title] | @tsv' "$story_path" |
    while IFS=$'\t' read -r tid tstatus ttitle; do
      printf "%-8s %-8s %s\n" "$tid" "$tstatus" "$ttitle"
    done
}

cmd_set_status() {
  local story_id="${1:-}" new_status="${2:-}" valid_statuses tmp
  [ -n "$story_id" ] && [ -n "$new_status" ] || fail "Usage: ralph-story.sh set-status <ID> <STATUS>"
  resolve_stories_file

  if command -v node >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/core/cli/update-story-status.mjs" ]; then
    node "$SCRIPT_DIR/core/cli/update-story-status.mjs" set-status "$STORIES_FILE" "$story_id" "$new_status"
    return $?
  fi

  valid_statuses="planned ready active done abandoned blocked"
  printf '%s\n' "$valid_statuses" | tr ' ' '\n' | rg -qx -- "$new_status" || fail "Invalid status '$new_status'. Valid: $valid_statuses"
  tmp="$(mktemp)"
  jq --arg id "$story_id" --arg s "$new_status" '(.stories[] | select(.id == $id) | .status) = $s' "$STORIES_FILE" > "$tmp"
  mv "$tmp" "$STORIES_FILE"
  echo "Story $story_id status set to: $new_status"
}

cmd_abandon() {
  local story_id="${1:-}" reason="${2:-}" tmp
  [ -n "$story_id" ] || fail "Usage: ralph-story.sh abandon <ID> [REASON]"
  resolve_stories_file

  if command -v node >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/core/cli/update-story-status.mjs" ]; then
    node "$SCRIPT_DIR/core/cli/update-story-status.mjs" abandon "$STORIES_FILE" "$story_id" "$reason"
    return $?
  fi

  tmp="$(mktemp)"
  jq --arg id "$story_id" --arg r "$reason" '(.stories[] | select(.id == $id)) |= . + {"status": "abandoned", "abandonReason": $r}' "$STORIES_FILE" > "$tmp"
  mv "$tmp" "$STORIES_FILE"
  echo "Story $story_id marked abandoned."
}
