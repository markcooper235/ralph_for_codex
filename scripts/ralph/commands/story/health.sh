#!/bin/bash
# Story health and validation commands.
#
# Lazy-loaded by ralph-story.sh. Sourcing this module performs no work. The
# host provides resolve_stories_file, resolve_story_path, STORIES_FILE, and
# WORKSPACE_ROOT.

_health_story() {
  local story_id="$1"
  local story_path
  story_path="$(resolve_story_path "$story_id")"
  local story_status
  story_status="$(jq -r --arg id "$story_id" '.stories[] | select(.id == $id) | .status' "$STORIES_FILE")"
  local issues=0

  echo "[$story_id] $story_status"

  if [ ! -f "$story_path" ]; then
    echo "  [MISSING] story.json not found: $story_path"
    return 1
  fi

  if jq -e '.migration.tasks_recovered == false' "$story_path" >/dev/null 2>&1; then
    if [ "$story_status" = "done" ] || [ "$story_status" = "abandoned" ]; then
      echo "  [INFO] Historical migration placeholder retained (task-level data was not recoverable)"
    else
      echo "  [MIGRATION] task-level data was not recovered; regenerate this story before execution"
      issues=$((issues + 1))
    fi
  fi

  # Validate SpecKit artifacts if .specify/ exists (catches partial SpecKit runs)
  local specify_dir
  specify_dir="$(dirname "$story_path")/.specify"
  if [ -d "$specify_dir" ]; then
    for artifact in spec.md plan.md tasks.md; do
      if [ ! -f "$specify_dir/$artifact" ]; then
        echo "  [SPECKIT] Missing artifact: $artifact (partial run — re-run specify with --force)"
        issues=$((issues + 1))
      elif [ ! -s "$specify_dir/$artifact" ]; then
        echo "  [SPECKIT] Empty artifact: $artifact"
        issues=$((issues + 1))
      fi
    done
  fi

  local task_count
  task_count="$(jq '.tasks | length' "$story_path")"
  if [ "$task_count" -eq 0 ]; then
    echo "  [WARN] No tasks defined"
    issues=$((issues + 1))
  fi

  # Per-task checks: missing checks, empty context, dead depends_on
  while IFS= read -r tid; do
    local check_count
    check_count="$(jq -r --arg id "$tid" '.tasks[] | select(.id == $id) | .checks | length' "$story_path")"
    if [ "$check_count" -eq 0 ]; then
      echo "  [WARN] $tid: no acceptance checks"
      issues=$((issues + 1))
    fi

    local ctx
    ctx="$(jq -r --arg id "$tid" '.tasks[] | select(.id == $id) | .context // ""' "$story_path")"
    if [ -z "$ctx" ] || [ "$ctx" = "null" ]; then
      echo "  [WARN] $tid: empty context"
      issues=$((issues + 1))
    fi

    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      local dep_exists
      dep_exists="$(jq -r --arg d "$dep" '.tasks[] | select(.id == $d) | .id' "$story_path")"
      if [ -z "$dep_exists" ]; then
        echo "  [DEAD] $tid: depends_on '$dep' not found in story"
        issues=$((issues + 1))
      fi
    done < <(jq -r --arg id "$tid" '.tasks[] | select(.id == $id) | .depends_on[]?' "$story_path")
  done < <(jq -r '.tasks[].id' "$story_path")

  # Duplicate checks within the same task's checks array
  while IFS= read -r tid; do
    local self_dups
    self_dups="$(jq -r --arg id "$tid" '
      (.tasks[] | select(.id == $id) | .checks // []) |
      group_by(.) | map(select(length > 1) | .[0]) | .[]
    ' "$story_path" 2>/dev/null || true)"
    if [ -n "$self_dups" ]; then
      while IFS= read -r dup; do
        [ -z "$dup" ] && continue
        echo "  [DUP]  $tid: check listed more than once: $dup"
        issues=$((issues + 1))
      done <<< "$self_dups"
    fi
  done < <(jq -r '.tasks[].id' "$story_path")

  # Tasks with identical check sets — only flag when titles are also similar
  # (same checks + similar titles = likely copy-paste error)
  local dup_task_sets
  dup_task_sets="$(jq -r '
    .tasks |
    map({id: .id, title: (.title // ""), checks: (.checks // [] | sort)}) |
    group_by(.checks) |
    map(select(length > 1)) |
    map(
      . as $group |
      [
        range($group | length) as $i |
        range($i + 1; $group | length) as $j |
        [$group[$i], $group[$j]] |
        select(
          (.[0].title | ascii_downcase) == (.[1].title | ascii_downcase)
          or (.[0].title | ascii_downcase | contains(.[1].title | ascii_downcase))
          or (.[1].title | ascii_downcase | contains(.[0].title | ascii_downcase))
        ) |
        "\(.[0].id), \(.[1].id)"
      ] |
      unique |
      .[]
    ) |
    .[]
  ' "$story_path" 2>/dev/null || true)"
  if [ -n "$dup_task_sets" ]; then
    while IFS= read -r set; do
      [ -z "$set" ] && continue
      echo "  [DUP]  Tasks share identical check sets and similar titles: $set"
      issues=$((issues + 1))
    done <<< "$dup_task_sets"
  fi

  # Self-referencing depends_on
  while IFS= read -r tid; do
    local self_dep
    self_dep="$(jq -r --arg id "$tid" '.tasks[] | select(.id == $id) | .depends_on[]? | select(. == $id)' "$story_path" 2>/dev/null || true)"
    if [ -n "$self_dep" ]; then
      echo "  [CYCLE] $tid: depends on itself"
      issues=$((issues + 1))
    fi
  done < <(jq -r '.tasks[].id' "$story_path")

  # Validate checks[] syntax and command reachability
  while IFS= read -r tid; do
    local cnum=0
    while IFS= read -r chk; do
      [ -z "$chk" ] && continue
      cnum=$((cnum + 1))
      if ! bash -n -c "$chk" 2>/dev/null; then
        echo "  [SYNTAX] $tid check[$cnum]: syntax error: $chk"
        issues=$((issues + 1))
      else
        local first_word
        first_word="$(printf '%s' "$chk" | awk '{print $1}')"
        case "$first_word" in
          test|'['|echo|true|false|printf|:) ;;
          grep|find|cat|ls|mkdir|rm|cp|mv|sed|awk|sort|head|tail|wc|cut|tr) ;;
          git|bash|sh|cd|source|.) ;;
          *)
            if ! command -v "$first_word" >/dev/null 2>&1; then
              echo "  [CMD?]  $tid check[$cnum]: '$first_word' not on PATH: $chk"
              issues=$((issues + 1))
            fi
            ;;
        esac
      fi
    done < <(jq -r --arg id "$tid" '.tasks[] | select(.id == $id) | .checks[]?' "$story_path")
  done < <(jq -r '.tasks[].id' "$story_path")

  if [ "$issues" -eq 0 ]; then
    echo "  OK"
    return 0
  fi
  return 1
}

cmd_health() {
  resolve_stories_file

  local story_id="${1:-}"

  if [ -n "$story_id" ]; then
    _health_story "$story_id"
    return $?
  fi

  local any_issues=0
  while IFS= read -r sid; do
    _health_story "$sid" || any_issues=1
  done < <(jq -r '.stories[] | select(.status != "done" and .status != "abandoned") | .id' "$STORIES_FILE")

  echo ""
  if [ "$any_issues" -eq 0 ]; then
    echo "All stories healthy."
  else
    echo "Issues found. Review warnings above."
    return 1
  fi
}

# health-all: full audit sweep including done/abandoned stories
cmd_health_all() {
  resolve_stories_file

  local any_issues=0
  while IFS= read -r sid; do
    _health_story "$sid" || any_issues=1
  done < <(jq -r '.stories[].id' "$STORIES_FILE")

  echo ""
  if [ "$any_issues" -eq 0 ]; then
    echo "All stories healthy (full audit)."
  else
    echo "Issues found. Review warnings above."
    return 1
  fi
}
