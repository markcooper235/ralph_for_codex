#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ./ralph.sh [max_iterations] [--bootstrap-prd]

set -euo pipefail

MAX_ITERATIONS=10
BOOTSTRAP_PRD=false
ALLOW_EPIC_FALLBACK=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
COMPLETION_STATE_FILE="$SCRIPT_DIR/.completion-state.json"
ACTIVE_PRD_FILE="$SCRIPT_DIR/.active-prd"
SPRINTS_DIR="$SCRIPT_DIR/sprints"
TASKS_DIR="$SCRIPT_DIR/tasks"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
EPICS_FILE=""
ARCHIVE_DIR="$TASKS_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"
SPRINT_BRANCH_PREFIX="ralph/sprint"

WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PLAYWRIGHT_CLI_DIR="$WORKSPACE_ROOT/.playwright-cli"
CODEX_BIN="${CODEX_BIN:-codex}"
ITERATION_TRANSCRIPT_LATEST_FILE="$SCRIPT_DIR/.iteration-log-latest.txt"
ITERATION_HANDOFF_LATEST_FILE="$SCRIPT_DIR/.iteration-handoff-latest.json"
PRIME_CMD="$SCRIPT_DIR/ralph-prime.sh"
LOCK_DIR="$SCRIPT_DIR/.workflow-lock"
EXPLICIT_SCOPE_SIGNAL_PATTERN='keep (source )?changes limited to|only change|change(s)? limited to|scoped work'
EXPLICIT_HELPER_PATH_PATTERN='^(scripts/[^/]+$|config/|configs/|vite\.config\.|webpack\.config\.|rollup\.config\.|playwright\.config\.|cypress\.config\.|package\.json$|package-lock\.json$|pnpm-lock\.yaml$|yarn\.lock$|tsconfig.*\.json$|eslint\.config\.|\.eslintrc|prettier\.config\.|\.prettierrc)'

for arg in "$@"; do
  case "$arg" in
    --bootstrap-prd)
      BOOTSTRAP_PRD=true
      ;;
    --allow-epic-fallback)
      ALLOW_EPIC_FALLBACK=true
      ;;
    -h|--help)
      echo "Usage: ./ralph.sh [max_iterations] [--bootstrap-prd] [--allow-epic-fallback]"
      echo ""
      echo "Options:"
      echo "  --bootstrap-prd     Attempt to auto-generate scripts/ralph/prd.json when missing/empty."
      echo "  --allow-epic-fallback  Allow switching from completed standalone PRD back into epic priming."
      echo ""
      echo "Environment:"
      echo "  RALPH_BOOTSTRAP_PRD=1  Enable PRD bootstrap behavior."
      exit 0
      ;;
    *)
      if [[ "$arg" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$arg"
      else
        echo "Unknown argument: $arg" >&2
        echo "Use --help for usage." >&2
        exit 1
      fi
      ;;
  esac
done

if [ "${RALPH_BOOTSTRAP_PRD:-0}" = "1" ] || [ "${RALPH_BOOTSTRAP_PRD:-}" = "true" ]; then
  BOOTSTRAP_PRD=true
fi
if [ "${RALPH_ALLOW_EPIC_FALLBACK:-0}" = "1" ] || [ "${RALPH_ALLOW_EPIC_FALLBACK:-}" = "true" ]; then
  ALLOW_EPIC_FALLBACK=true
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

acquire_workflow_lock() {
  if [ "${RALPH_LOCK_HELD:-0}" = "1" ]; then
    return 0
  fi

  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another Ralph workflow command is already running. Wait for it to finish and retry." >&2
    exit 1
  fi

  export RALPH_LOCK_HELD=1
  trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT
}

get_active_sprint() {
  if [ -f "$ACTIVE_SPRINT_FILE" ]; then
    awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE"
    return 0
  fi
  return 1
}

sprint_branch_name() {
  local sprint="$1"
  printf '%s/%s' "$SPRINT_BRANCH_PREFIX" "$sprint"
}

default_base_branch() {
  if git show-ref --verify --quiet refs/heads/master; then
    printf 'master\n'
    return 0
  fi
  if git show-ref --verify --quiet refs/heads/main; then
    printf 'main\n'
    return 0
  fi
  echo "Could not find base branch (master or main)." >&2
  return 1
}

ensure_sprint_branch_exists() {
  local sprint="$1"
  local sprint_branch base_branch
  sprint_branch="$(sprint_branch_name "$sprint")"
  if git show-ref --verify --quiet "refs/heads/$sprint_branch"; then
    return 0
  fi

  base_branch="$(default_base_branch)"
  git branch "$sprint_branch" "$base_branch"
  echo "Created sprint branch $sprint_branch from base branch $base_branch."
}

resolve_sprint_paths() {
  local active_sprint
  active_sprint="$(get_active_sprint || true)"
  if [ -z "$active_sprint" ]; then
    EPICS_FILE=""
    ARCHIVE_DIR="$TASKS_DIR/archive"
    return 0
  fi
  EPICS_FILE="$SPRINTS_DIR/$active_sprint/epics.json"
  ARCHIVE_DIR="$TASKS_DIR/archive/$active_sprint"
  return 0
}

supports_codex_yolo() {
  local out
  out="$("$CODEX_BIN" --yolo exec --help 2>&1 || true)"
  if echo "$out" | grep -qi "unexpected argument '--yolo'"; then
    return 1
  fi
  if echo "$out" | grep -qi "Run Codex non-interactively"; then
    return 0
  fi
  return 1
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\/&]/\\&/g'
}

file_has_non_whitespace() {
  local path="$1"
  [ -f "$path" ] || return 1
  grep -q '[^[:space:]]' "$path"
}

local_prompt_has_named_blocks() {
  local path="$1"
  [ -f "$path" ] || return 1
  grep -Eq '^[[:space:]]*<!--[[:space:]]*RALPH:LOCAL:[A-Za-z0-9:_-]+[[:space:]]*-->[[:space:]]*$' "$path"
}

local_prompt_block_keys() {
  local path="$1"
  awk '
    match($0, /^[[:space:]]*<!--[[:space:]]*RALPH:LOCAL:([A-Za-z0-9:_-]+)[[:space:]]*-->[[:space:]]*$/, m) {
      key = m[1]
      if (!seen[key]++) print key
    }
  ' "$path"
}

prompt_has_matching_local_marker() {
  local local_prompt_path="$1"
  local prompt_path="$2"
  local key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if grep -Eq "^[[:space:]]*<!--[[:space:]]*RALPH:LOCAL:${key}[[:space:]]*-->[[:space:]]*$" "$prompt_path"; then
      return 0
    fi
  done < <(local_prompt_block_keys "$local_prompt_path")
  return 1
}

inject_local_prompt_blocks() {
  local local_prompt_path="$1"
  local rendered_prompt_path="$2"

  awk '
    FNR == NR {
      if (match($0, /^[[:space:]]*<!--[[:space:]]*RALPH:LOCAL:([A-Za-z0-9:_-]+)[[:space:]]*-->[[:space:]]*$/, m)) {
        current = m[1]
        in_block = 1
        if (!(current in block_order_seen)) {
          block_order[++block_count] = current
          block_order_seen[current] = 1
          block_content[current] = ""
        }
        next
      }

      if (match($0, /^[[:space:]]*<!--[[:space:]]*\/RALPH:LOCAL:([A-Za-z0-9:_-]+)[[:space:]]*-->[[:space:]]*$/, m)) {
        if (in_block && m[1] == current) {
          in_block = 0
          current = ""
        }
        next
      }

      if (in_block) {
        block_content[current] = block_content[current] $0 ORS
      }
      next
    }

    {
      if (match($0, /^([[:space:]]*)<!--[[:space:]]*RALPH:LOCAL:([A-Za-z0-9:_-]+)[[:space:]]*-->[[:space:]]*$/, m)) {
        indent = m[1]
        key = m[2]
        if (key in block_content) {
          line_count = split(block_content[key], lines, /\n/)
          min_leading = -1
          for (i = 1; i <= line_count; i++) {
            if (i == line_count && lines[i] == "") {
              continue
            }
            if (lines[i] == "") {
              continue
            }
            non_ws_pos = match(lines[i], /[^ \t]/)
            if (non_ws_pos == 0) {
              leading = length(lines[i])
            } else {
              leading = non_ws_pos - 1
            }
            if (min_leading == -1 || leading < min_leading) {
              min_leading = leading
            }
          }
          if (min_leading < 0) {
            min_leading = 0
          }
          for (i = 1; i <= line_count; i++) {
            if (i == line_count && lines[i] == "") {
              continue
            }
            if (lines[i] == "") {
              print ""
            } else {
              normalized_line = lines[i]
              if (min_leading > 0) {
                normalized_line = substr(normalized_line, min_leading + 1)
              }
              print indent normalized_line
            }
          }
          next
        }
      }
      print
    }
  ' "$local_prompt_path" "$rendered_prompt_path"
}

slugify_branch() {
  printf '%s' "$1" \
    | sed 's|^ralph/||' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's|[^a-z0-9._-]+|-|g' \
    | sed -E 's|^-+||; s|-+$||'
}

has_archived_run_for_branch() {
  local branch="$1"
  local manifest
  [ -d "$ARCHIVE_DIR" ] || return 1

  while IFS= read -r manifest; do
    [ -f "$manifest" ] || continue
    if [ "$(awk -F= '/^source_branch=/{print $2}' "$manifest" | tail -n 1)" = "$branch" ]; then
      return 0
    fi
  done < <(find "$ARCHIVE_DIR" -maxdepth 2 -type f -name 'archive-manifest.txt' 2>/dev/null | sort)

  return 1
}

reset_local_run_artifacts() {
  local iter_transcript iter_handoff

  rm -f "$ITERATION_TRANSCRIPT_LATEST_FILE" "$ITERATION_HANDOFF_LATEST_FILE" "$COMPLETION_STATE_FILE"
  for iter_transcript in "$SCRIPT_DIR"/.iteration-log-iter-*.txt; do
    [ -f "$iter_transcript" ] || continue
    rm -f "$iter_transcript"
  done
  for iter_handoff in "$SCRIPT_DIR"/.iteration-handoff-iter-*.json; do
    [ -f "$iter_handoff" ] || continue
    rm -f "$iter_handoff"
  done
  [ -d "$PLAYWRIGHT_CLI_DIR" ] && rm -rf "$PLAYWRIGHT_CLI_DIR"

  {
    echo "# Ralph Progress Log"
    echo "Started: $(date)"
    echo "---"
  } > "$PROGRESS_FILE"
}

has_live_run_artifacts() {
  local iter_transcript iter_handoff
  for iter_transcript in "$SCRIPT_DIR"/.iteration-log-iter-*.txt; do
    [ -f "$iter_transcript" ] && return 0
  done
  for iter_handoff in "$SCRIPT_DIR"/.iteration-handoff-iter-*.json; do
    [ -f "$iter_handoff" ] && return 0
  done

  [ -d "$PLAYWRIGHT_CLI_DIR" ] && return 0
  return 1
}

read_latest_iteration_handoff_prompt() {
  [ -f "$ITERATION_HANDOFF_LATEST_FILE" ] || return 1
  jq -r '
    "## Latest Iteration Handoff\n" +
    "- Status: " + (.status // "unknown") + "\n" +
    (
      if (.story.id // "") != "" or (.story.title // "") != "" then
        "- Story: " + ((.story.id // "") + (if (.story.id // "") != "" and (.story.title // "") != "" then " - " else "" end) + (.story.title // "")) + "\n"
      else
        ""
      end
    ) +
    (
      if (.summary // "") != "" then
        "- Summary: " + .summary + "\n"
      else
        ""
      end
    ) +
    (
      if ((.errors // []) | length) > 0 then
        "- Errors: " + ((.errors // []) | join(" | ")) + "\n"
      else
        ""
      end
    ) +
    (
      if ((.directionChanges // []) | length) > 0 then
        "- Direction Changes: " + ((.directionChanges // []) | join(" | ")) + "\n"
      else
        ""
      end
    ) +
    (
      if ((.verification // []) | length) > 0 then
        "- Verification: " + ((.verification // []) | join(" | ")) + "\n"
      else
        ""
      end
    ) +
    (
      if ((.nextLoopAdvice // []) | length) > 0 then
        "- Next Loop Advice: " + ((.nextLoopAdvice // []) | join(" | ")) + "\n"
      else
        ""
      end
    )
  ' "$ITERATION_HANDOFF_LATEST_FILE" 2>/dev/null
}

require_previous_run_archived() {
  local current_branch last_branch
  [ -f "$PRD_FILE" ] || return 0
  [ -f "$LAST_BRANCH_FILE" ] || return 0

  current_branch="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || true)"
  last_branch="$(cat "$LAST_BRANCH_FILE" 2>/dev/null || true)"

  if [ -z "$current_branch" ] || [ -z "$last_branch" ] || [ "$current_branch" = "$last_branch" ]; then
    return 0
  fi

  if ! has_live_run_artifacts; then
    return 0
  fi

  if has_archived_run_for_branch "$last_branch"; then
    echo "Previous run ($last_branch) already archived; resetting stale local run artifacts."
    reset_local_run_artifacts
    return 0
  fi

  echo "Previous run artifacts for $last_branch are still present and not archived." >&2
  echo "Run ./scripts/ralph/ralph-commit.sh (or ./scripts/ralph/ralph-archive.sh) before starting a new loop." >&2
  return 1
}

render_prompt() {
  local ralph_dir prd_file progress_file local_prompt_file rendered_prompt_file
  local handoff_prompt=""
  ralph_dir="$(escape_sed_replacement "$SCRIPT_DIR")"
  prd_file="$(escape_sed_replacement "$PRD_FILE")"
  progress_file="$(escape_sed_replacement "$PROGRESS_FILE")"
  local_prompt_file="$SCRIPT_DIR/prompt.local.md"
  rendered_prompt_file="$(mktemp)"
  handoff_prompt="$(read_latest_iteration_handoff_prompt || true)"

  sed \
    -e "s|{{RALPH_DIR}}|$ralph_dir|g" \
    -e "s|{{PRD_FILE}}|$prd_file|g" \
    -e "s|{{PROGRESS_FILE}}|$progress_file|g" \
    "$SCRIPT_DIR/prompt.md" >"$rendered_prompt_file"

  if ! file_has_non_whitespace "$local_prompt_file"; then
    cat "$rendered_prompt_file"
    if [ -n "$handoff_prompt" ]; then
      printf '\n\n%s\n' "$handoff_prompt"
    fi
    rm -f "$rendered_prompt_file"
    return 0
  fi

  if local_prompt_has_named_blocks "$local_prompt_file" && prompt_has_matching_local_marker "$local_prompt_file" "$SCRIPT_DIR/prompt.md"; then
    inject_local_prompt_blocks "$local_prompt_file" "$rendered_prompt_file"
    if [ -n "$handoff_prompt" ]; then
      printf '\n\n%s\n' "$handoff_prompt"
    fi
    rm -f "$rendered_prompt_file"
    return 0
  fi

  cat "$rendered_prompt_file"
  rm -f "$rendered_prompt_file"
  printf '\n\n## Local Prompt Extensions\n'
  printf '(Loaded from `%s`; preserved across framework updates.)\n\n' "$local_prompt_file"
  cat "$local_prompt_file"
  if [ -n "$handoff_prompt" ]; then
    printf '\n\n%s\n' "$handoff_prompt"
  fi
}

extract_ralph_handoff_json() {
  local source_file="$1"
  awk '
    /<ralph_handoff>/ {
      in_block = 1
      block = ""
      next
    }
    /<\/ralph_handoff>/ {
      if (in_block) {
        latest = block
      }
      in_block = 0
      next
    }
    in_block {
      block = block $0 ORS
    }
    END {
      printf "%s", latest
    }
  ' "$source_file"
}

handoff_completion_evidence_present() {
  prd_all_passes || return 1
  has_non_transient_worktree_changes && return 1
  full_verification_recorded
}

handoff_schema_is_valid() {
  local path="$1"
  [ -f "$path" ] || return 1
  jq -e '
    (.status | type == "string")
    and (.status | IN("progressed", "blocked", "no_change", "completed"))
    and (.summary | type == "string")
    and (.summary | length > 0)
    and (.completionSignal | type == "boolean")
    and (
      [.errors, .directionChanges, .verification, .filesChanged, .assumptions, .nextLoopAdvice]
      | all(.[]; type == "array" and length <= 2 and all(.[]; type == "string"))
    )
    and (
      if .status == "no_change" then
        true
      else
        (.story | type == "object")
        and (.story.id | type == "string")
        and (.story.id | length > 0)
        and (.story.title | type == "string")
        and (.story.title | length > 0)
      end
    )
    and (
      (.status == "completed" and .completionSignal == true)
      or (.status != "completed" and .completionSignal == false)
    )
  ' "$path" >/dev/null 2>&1
}

handoff_completion_state_is_valid() {
  local path="$1"
  handoff_schema_is_valid "$path" || return 1
  if jq -e '.completionSignal == true' "$path" >/dev/null 2>&1; then
    handoff_completion_evidence_present
    return $?
  fi
  return 0
}

fallback_story_from_prd() {
  local target_status="$1"
  [ -f "$PRD_FILE" ] || return 0
  jq -r --arg status "$target_status" '
    if (.userStories | type != "array") or ((.userStories | length) == 0) then
      ""
    else
      (
        if $status == "completed" then
          ([.userStories[] | select(.passes == true)] | sort_by(.priority) | first)
        elif $status == "blocked" then
          ([.userStories[] | select(.passes != true)] | sort_by(.priority) | first)
        else
          ([.userStories[]] | sort_by(.priority) | first)
        end
      ) as $story
      | if $story == null then "" else ($story.id // "") + "\t" + ($story.title // "") end
    end
  ' "$PRD_FILE" 2>/dev/null || true
}

write_fallback_handoff() {
  local output_path="$1"
  local iteration="$2"
  local timestamp="$3"
  local branch="$4"
  local status="$5"
  local summary="$6"
  local error_message="${7:-}"
  local next_advice="${8:-}"
  local completion="${9:-false}"
  local story_context story_id story_title

  story_context="$(fallback_story_from_prd "$status")"
  story_id="${story_context%%$'\t'*}"
  if [ "$story_context" = "$story_id" ]; then
    story_title=""
  else
    story_title="${story_context#*$'\t'}"
  fi

  jq -n \
    --argjson iteration "$iteration" \
    --arg timestamp "$timestamp" \
    --arg branch "$branch" \
    --arg status "$status" \
    --arg summary "$summary" \
    --arg error_message "$error_message" \
    --arg next_advice "$next_advice" \
    --arg story_id "$story_id" \
    --arg story_title "$story_title" \
    --argjson completion "$completion" \
    '{
      iteration: $iteration,
      timestamp: $timestamp,
      branch: $branch,
      status: $status,
      story: (
        if $status == "no_change" or (($story_id | length) == 0 and ($story_title | length) == 0) then
          {}
        else
          {
            id: $story_id,
            title: $story_title
          }
        end
      ),
      summary: $summary,
      errors: (if ($error_message | length) > 0 then [$error_message] else [] end),
      directionChanges: [],
      verification: [],
      filesChanged: [],
      assumptions: [],
      nextLoopAdvice: (if ($next_advice | length) > 0 then [$next_advice] else [] end),
      completionSignal: $completion
    }' > "$output_path"
}

write_codex_failure_handoff() {
  local output_path="$1"
  local iteration="$2"
  local timestamp="$3"
  local branch="$4"
  local exit_code="$5"

  write_fallback_handoff \
    "$output_path" \
    "$iteration" \
    "$timestamp" \
    "$branch" \
    "blocked" \
    "Codex command failed before Ralph could validate iteration output." \
    "Codex exited with status $exit_code." \
    "Review the latest transcript and retry the iteration after fixing the Codex/runtime failure." \
    false
}

finalize_handoff_json() {
  local output_path="$1"
  local iteration="$2"
  local timestamp="$3"
  local branch="$4"
  local source_json="$5"
  local tmp_json

  tmp_json="$(mktemp)"

  if [ -n "$source_json" ] && ! printf '%s\n' "$source_json" | jq -e '.' >/dev/null 2>&1; then
    if handoff_completion_evidence_present; then
      write_fallback_handoff "$tmp_json" "$iteration" "$timestamp" "$branch" "completed" "Completion inferred from Ralph state despite invalid handoff JSON." "" "" true
    else
      write_fallback_handoff "$tmp_json" "$iteration" "$timestamp" "$branch" "blocked" "Iteration emitted invalid structured handoff JSON." "Invalid handoff JSON emitted; review latest transcript." "Emit valid JSON inside the <ralph_handoff> wrapper." false
    fi
  elif [ -n "$source_json" ]; then
    printf '%s\n' "$source_json" | jq \
      --argjson iteration "$iteration" \
      --arg timestamp "$timestamp" \
      --arg branch "$branch" \
      '
      .iteration = $iteration
      | .timestamp = $timestamp
      | .branch = $branch
      ' > "$tmp_json"

    if handoff_completion_evidence_present; then
      jq '.status = "completed" | .completionSignal = true' "$tmp_json" > "${tmp_json}.completed"
      mv "${tmp_json}.completed" "$tmp_json"
    fi

    if ! handoff_schema_is_valid "$tmp_json"; then
      if handoff_completion_evidence_present; then
        write_fallback_handoff "$tmp_json" "$iteration" "$timestamp" "$branch" "completed" "Completion inferred from Ralph state despite invalid handoff schema." "" "" true
      else
        write_fallback_handoff "$tmp_json" "$iteration" "$timestamp" "$branch" "blocked" "Iteration emitted an invalid structured handoff." "Invalid handoff schema emitted; review latest transcript." "Emit a valid handoff schema with consistent status and completion fields." false
      fi
    elif ! handoff_completion_state_is_valid "$tmp_json"; then
      write_fallback_handoff "$tmp_json" "$iteration" "$timestamp" "$branch" "blocked" "Iteration claimed completion without matching Ralph state." "Completion handoff disagreed with PRD/progress state." "Only mark completion after stories pass and a completion entry is recorded." false
    fi
  else
    if handoff_completion_evidence_present; then
      write_fallback_handoff "$tmp_json" "$iteration" "$timestamp" "$branch" "completed" "Completion inferred from Ralph state." "" "" true
    else
      write_fallback_handoff "$tmp_json" "$iteration" "$timestamp" "$branch" "no_change" "Iteration completed without a structured handoff block." "" "" false
    fi
  fi

  mv "$tmp_json" "$output_path"
}

write_iteration_handoff() {
  local iteration="$1"
  local transcript_file="$2"
  local codex_exit_code="${3:-0}"
  local output_file="$SCRIPT_DIR/.iteration-handoff-iter-$iteration.json"
  local source_json branch_name timestamp
  source_json=""

  if [ -f "$transcript_file" ] && [ "$codex_exit_code" -eq 0 ]; then
    source_json="$(extract_ralph_handoff_json "$transcript_file" || true)"
  fi

  branch_name="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || true)"
  timestamp="$(date -Iseconds)"
  if [ "$codex_exit_code" -ne 0 ]; then
    write_codex_failure_handoff "$output_file" "$iteration" "$timestamp" "$branch_name" "$codex_exit_code"
  else
    finalize_handoff_json "$output_file" "$iteration" "$timestamp" "$branch_name" "$source_json"
  fi
  cp -f "$output_file" "$ITERATION_HANDOFF_LATEST_FILE" >/dev/null 2>&1 || true
}

progress_has_completion_entry() {
  [ -f "$PROGRESS_FILE" ] || return 1
  grep -Eq '^## .+ - (COMPLETE|Completion)$|^## Completion Note$' "$PROGRESS_FILE"
}

full_verification_recorded() {
  [ -f "$PROGRESS_FILE" ] || return 1
  grep -Eiq '(\./scripts/ralph/ralph-verify\.sh --full|full verification passed)' "$PROGRESS_FILE"
}

write_completion_state() {
  local iteration="$1"
  local branch_name="$2"
  local timestamp
  timestamp="$(date -Iseconds)"

  jq -n \
    --argjson iteration "$iteration" \
    --arg branch "$branch_name" \
    --arg timestamp "$timestamp" \
    '{
      status: "completed",
      completionSignal: true,
      iteration: $iteration,
      branch: $branch,
      recordedAt: $timestamp
    }' > "$COMPLETION_STATE_FILE"
}

append_wrapper_completion_entry() {
  local iteration="$1"
  progress_has_completion_entry && return 0
  [ -f "$PROGRESS_FILE" ] || return 1

  cat >> "$PROGRESS_FILE" <<EOF
## [$(date '+%Y-%m-%d %H:%M:%S %Z')] - Completion
Codex transcript: $SCRIPT_DIR/.iteration-log-iter-*.txt (latest)
- Implemented: Ralph finalized completion after strict validation of passing stories, a clean non-transient worktree, and recorded full verification evidence
- Files changed: scripts/ralph/progress.txt, scripts/ralph/.completion-state.json, scripts/ralph/.iteration-handoff-iter-$iteration.json, scripts/ralph/.iteration-handoff-latest.json
- Learnings (reusable only): wrapper-owned completion finalization is authoritative once stories pass and full verification is recorded
---
EOF
}

clear_completion_state() {
  rm -f "$COMPLETION_STATE_FILE"
}

completion_state_is_valid() {
  [ -f "$COMPLETION_STATE_FILE" ] || return 1
  jq -e '
    (.status == "completed")
    and (.completionSignal == true)
    and (.iteration | type == "number")
    and (.iteration >= 1)
    and (.branch | type == "string")
    and (.recordedAt | type == "string")
  ' "$COMPLETION_STATE_FILE" >/dev/null 2>&1
}

legacy_completion_evidence_present() {
  progress_has_completion_entry || return 1
  full_verification_recorded
}

strict_completion_ready() {
  prd_all_passes || return 1
  has_non_transient_worktree_changes && return 1
  full_verification_recorded
}

write_wrapper_completed_handoff() {
  local output_path="$1"
  local iteration="$2"
  local branch_name="$3"
  local timestamp
  timestamp="$(date -Iseconds)"

  write_fallback_handoff \
    "$output_path" \
    "$iteration" \
    "$timestamp" \
    "$branch_name" \
    "completed" \
    "Completion finalized by Ralph after strict validation of passing stories and full verification evidence." \
    "" \
    "Proceed to Ralph completion handling; no further model iteration is required." \
    true
}

finalize_wrapper_completion() {
  local iteration="$1"
  local branch_name="$2"
  local handoff_file="$SCRIPT_DIR/.iteration-handoff-iter-$iteration.json"

  strict_completion_ready || return 1
  append_wrapper_completion_entry "$iteration" || true
  write_completion_state "$iteration" "$branch_name"
  write_wrapper_completed_handoff "$handoff_file" "$iteration" "$branch_name"
  cp -f "$handoff_file" "$ITERATION_HANDOFF_LATEST_FILE" >/dev/null 2>&1 || true
  return 0
}

latest_handoff_signals_completion() {
  [ -f "$ITERATION_HANDOFF_LATEST_FILE" ] || return 1
  handoff_completion_state_is_valid "$ITERATION_HANDOFF_LATEST_FILE" || return 1
  jq -e '.completionSignal == true and (.status == "completed")' "$ITERATION_HANDOFF_LATEST_FILE" >/dev/null 2>&1
}

get_active_prd_source_path() {
  [ -f "$ACTIVE_PRD_FILE" ] || return 1
  jq -r '.sourcePath // empty' "$ACTIVE_PRD_FILE" 2>/dev/null
}

is_verification_only_path() {
  local path="$1"
  case "$path" in
    tests/*|test/*|__tests__/*|e2e/*|cypress/*|playwright/*|*.test.*|*.spec.*)
      return 0
      ;;
  esac
  return 1
}

scope_signal_present() {
  local text="$1"
  printf '%s\n' "$text" | tr '[:upper:]' '[:lower:]' | grep -Eq \
    "$EXPLICIT_SCOPE_SIGNAL_PATTERN"
}

extract_explicit_scope_paths() {
  local text="$1"
  printf '%s\n' "$text" \
    | awk '
        BEGIN { IGNORECASE=1 }
        /'"$EXPLICIT_SCOPE_SIGNAL_PATTERN"'/ { print }
      ' \
    | grep -Eo '([A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+\.[A-Za-z0-9]+' \
    | sort -u
}

collect_scope_hint_text() {
  local source_path
  source_path="$(get_active_prd_source_path || true)"

  if [ -n "$source_path" ] && [ -f "$WORKSPACE_ROOT/$source_path" ]; then
    cat "$WORKSPACE_ROOT/$source_path"
    printf '\n'
  fi

  if [ -f "$PRD_FILE" ]; then
    jq -r '
      [.description, (.userStories[]?.notes // ""), (.userStories[]?.acceptanceCriteria[]? // "")]
      | map(select(type == "string" and length > 0))
      | .[]
    ' "$PRD_FILE" 2>/dev/null || true
  fi
}

explicit_scope_allowed_paths() {
  local scope_text="$1"
  scope_signal_present "$scope_text" || return 1

  local allowed_paths
  allowed_paths="$(extract_explicit_scope_paths "$scope_text")"
  [ -n "$allowed_paths" ] || return 1
  printf '%s\n' "$allowed_paths"
}

structured_scope_allowed_paths() {
  [ -f "$PRD_FILE" ] || return 1

  jq -r '
    [
      (.scopePaths // []),
      (.userStories[]?.scopePaths // [])
    ]
    | flatten
    | map(select(type == "string" and length > 0))
    | unique
    | .[]
  ' "$PRD_FILE" 2>/dev/null
}

all_allowed_scope_paths() {
  local scope_text="$1"
  {
    structured_scope_allowed_paths || true
    explicit_scope_allowed_paths "$scope_text" || true
  } | sed '/^$/d' | sort -u
}

is_helper_or_config_path() {
  local path="$1"
  printf '%s\n' "$path" | grep -Eq "$EXPLICIT_HELPER_PATH_PATTERN"
}

changed_paths_outside_scope() {
  local allowed_paths="$1"
  local changed_paths="$2"

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if printf '%s\n' "$allowed_paths" | grep -qx "$path"; then
      continue
    fi
    if is_verification_only_path "$path"; then
      continue
    fi
    printf '%s\n' "$path"
  done <<< "$changed_paths"
}

changed_helper_paths_without_explicit_scope() {
  local allowed_paths="$1"
  local changed_paths="$2"

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if ! is_helper_or_config_path "$path"; then
      continue
    fi
    if printf '%s\n' "$allowed_paths" | grep -qx "$path"; then
      continue
    fi
    printf '%s\n' "$path"
  done <<< "$changed_paths"
}

ensure_explicit_scope_changes_valid() {
  local from_ref="$1"
  local to_ref="$2"
  local scope_text allowed_paths changed_files bad_changes disallowed_helper_changes

  scope_text="$(collect_scope_hint_text)"
  allowed_paths="$(all_allowed_scope_paths "$scope_text" || true)"

  changed_files="$(
    git log --name-only --pretty=format: "$from_ref..$to_ref" 2>/dev/null \
      | sed '/^$/d' \
      | sort -u
  )"
  [ -n "$changed_files" ] || return 0

  disallowed_helper_changes="$(changed_helper_paths_without_explicit_scope "$allowed_paths" "$changed_files")"
  if [ -n "$disallowed_helper_changes" ]; then
    echo "Ralph iteration changed helper/config/build files without explicit scope approval:" >&2
    printf '%s\n' "$disallowed_helper_changes" >&2
    echo "Add those exact paths to prd.json scopePaths (or story scopePaths) only when they are truly in scope." >&2
    return 1
  fi

  [ -n "$allowed_paths" ] || return 0

  bad_changes="$(changed_paths_outside_scope "$allowed_paths" "$changed_files")"

  if [ -n "$bad_changes" ]; then
    echo "Ralph iteration changed files outside explicit scoped implementation paths:" >&2
    printf '%s\n' "$bad_changes" >&2
    echo "Allowed implementation paths:" >&2
    printf '%s\n' "$allowed_paths" >&2
    echo "Only verification/test files may expand beyond explicit source scope." >&2
    return 1
  fi

  return 0
}

ensure_explicit_scope_worktree_valid() {
  local scope_text allowed_paths changed_files bad_changes disallowed_helper_changes

  scope_text="$(collect_scope_hint_text)"
  allowed_paths="$(all_allowed_scope_paths "$scope_text" || true)"

  changed_files="$(
    git status --porcelain --untracked-files=all 2>/dev/null \
      | awk '
          {
            path = substr($0, 4)
            if (path ~ /^scripts\/ralph\/prd\.json$/) next
            if (path ~ /^scripts\/ralph\/progress\.txt$/) next
            if (path ~ /^scripts\/ralph\/\.completion-state\.json$/) next
            if (path ~ /^scripts\/ralph\/\.active-prd$/) next
            if (path ~ /^scripts\/ralph\/\.last-branch$/) next
            if (path ~ /^scripts\/ralph\/\.iteration-log(\-iter-[0-9]+|-latest)?\.txt$/) next
            if (path ~ /^scripts\/ralph\/\.iteration-handoff(\-iter-[0-9]+|-latest)?\.json$/) next
            if (path ~ /^\.playwright-cli(\/|$)/) next
            if (path ~ /^scripts\/ralph\/\.playwright-cli(\/|$)/) next
            print path
          }
        ' \
      | sed '/^$/d' \
      | sort -u
  )"
  [ -n "$changed_files" ] || return 0

  disallowed_helper_changes="$(changed_helper_paths_without_explicit_scope "$allowed_paths" "$changed_files")"
  if [ -n "$disallowed_helper_changes" ]; then
    echo "Ralph iteration has helper/config/build files outside explicit scope approval:" >&2
    printf '%s\n' "$disallowed_helper_changes" >&2
    echo "Add those exact paths to prd.json scopePaths (or story scopePaths) only when they are truly in scope." >&2
    return 1
  fi

  [ -n "$allowed_paths" ] || return 0

  bad_changes="$(changed_paths_outside_scope "$allowed_paths" "$changed_files")"
  [ -z "$bad_changes" ] && return 0

  echo "Ralph iteration has uncommitted files outside explicit scoped implementation paths:" >&2
  printf '%s\n' "$bad_changes" >&2
  echo "Allowed implementation paths:" >&2
  printf '%s\n' "$allowed_paths" >&2
  echo "Only verification/test files may expand beyond explicit source scope." >&2
  return 1
}

prd_all_passes() {
  [ -f "$PRD_FILE" ] || return 1
  jq -e '(.userStories | length) > 0 and all(.userStories[]; .passes == true)' "$PRD_FILE" >/dev/null 2>&1
}

has_non_transient_worktree_changes() {
  local status_output filtered
  status_output="$(git status --porcelain --untracked-files=all || true)"
  [ -n "$status_output" ] || return 1

  filtered="$(
    printf '%s\n' "$status_output" | awk '
      {
        path = substr($0, 4)
        if (path ~ /^scripts\/ralph\/prd\.json$/) next
        if (path ~ /^scripts\/ralph\/progress\.txt$/) next
        if (path ~ /^scripts\/ralph\/\.completion-state\.json$/) next
        if (path ~ /^scripts\/ralph\/\.active-prd$/) next
        if (path ~ /^scripts\/ralph\/\.last-branch$/) next
        if (path ~ /^scripts\/ralph\/\.iteration-log(\-iter-[0-9]+|-latest)?\.txt$/) next
        if (path ~ /^scripts\/ralph\/\.iteration-handoff(\-iter-[0-9]+|-latest)?\.json$/) next
        if (path ~ /^scripts\/ralph\/tasks(\/[^/]+)?\/?$/) next
        if (path ~ /^scripts\/ralph\/tasks\/[^/]+\/prd-epic-[^/]+\.md$/) next
        if (path ~ /^\.playwright-cli(\/|$)/) next
        if (path ~ /^scripts\/ralph\/\.playwright-cli(\/|$)/) next
        print
      }
    '
  )"

  [ -n "$filtered" ]
}

completion_is_stable() {
  prd_all_passes || return 1
  has_non_transient_worktree_changes && return 1
  if completion_state_is_valid; then
    return 0
  fi
  legacy_completion_evidence_present || return 1
  latest_handoff_signals_completion
}

prd_has_unfinished_stories() {
  [ -f "$PRD_FILE" ] || return 1
  jq -e '(.userStories | length) > 0 and any(.userStories[]; .passes != true)' "$PRD_FILE" >/dev/null 2>&1
}

is_prd_empty() {
  [ ! -f "$PRD_FILE" ] || [ ! -s "$PRD_FILE" ] || ! grep -q '[^[:space:]]' "$PRD_FILE"
}

prd_is_valid_json() {
  [ -f "$PRD_FILE" ] && jq -e '.' "$PRD_FILE" >/dev/null 2>&1
}

get_active_prd_mode() {
  [ -f "$ACTIVE_PRD_FILE" ] || return 1
  jq -r '.mode // empty' "$ACTIVE_PRD_FILE" 2>/dev/null
}

standalone_prd_is_active() {
  [ "$(get_active_prd_mode || true)" = "standalone" ]
}

infer_prd_mode_from_branch() {
  local prd_branch
  prd_is_valid_json || return 1
  prd_branch="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || true)"
  if [[ "$prd_branch" =~ ^ralph/epic-[A-Za-z0-9-]+$ ]] || [[ "$prd_branch" =~ ^ralph/[^/]+/epic-[A-Za-z0-9-]+$ ]]; then
    printf 'epic\n'
  else
    printf 'standalone\n'
  fi
}

infer_epic_id_from_branch_path() {
  local branch_path="$1"
  local epic_suffix=""
  if [[ "$branch_path" =~ ^ralph/epic-([A-Za-z0-9-]+)$ ]]; then
    epic_suffix="${BASH_REMATCH[1]}"
  elif [[ "$branch_path" =~ ^ralph/[^/]+/epic-([A-Za-z0-9-]+)$ ]]; then
    epic_suffix="${BASH_REMATCH[1]}"
  fi

  if [ -n "$epic_suffix" ]; then
    printf 'EPIC-%s\n' "$(printf '%s' "$epic_suffix" | tr '[:lower:]' '[:upper:]')"
    return 0
  fi
  printf ''
  return 1
}

write_active_prd_state() {
  local mode="$1"
  local source_path="${2:-scripts/ralph/prd.json}"
  local epic_id=""
  local base_branch=""
  if [ "$mode" = "epic" ]; then
    local prd_branch
    prd_branch="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || true)"
    epic_id="$(infer_epic_id_from_branch_path "$prd_branch" || true)"
    local active_sprint
    active_sprint="$(get_active_sprint || true)"
    if [ -n "$active_sprint" ]; then
      base_branch="$(sprint_branch_name "$active_sprint")"
    fi
  else
    base_branch="$(default_base_branch || true)"
  fi
  cat >"$ACTIVE_PRD_FILE" <<EOF
{
  "mode": "$mode",
  "baseBranch": "${base_branch}",
  "sourcePath": "$source_path",
  "epicId": "${epic_id}",
  "activatedAt": "$(date -Iseconds)"
}
EOF
}

sync_active_prd_mode_with_current_prd() {
  local inferred_mode active_mode
  inferred_mode="$(infer_prd_mode_from_branch || true)"
  [ -n "$inferred_mode" ] || return 0
  active_mode="$(get_active_prd_mode || true)"
  if [ -z "$active_mode" ] || [ "$active_mode" != "$inferred_mode" ]; then
    write_active_prd_state "$inferred_mode" "scripts/ralph/prd.json"
    echo "Updated scripts/ralph/.active-prd mode to '$inferred_mode' based on current PRD branch."
  fi
}

build_codex_exec_args() {
  local -n out_args_ref="$1"

  if supports_codex_yolo; then
    out_args_ref=(--yolo exec -C "$WORKSPACE_ROOT" -)
  else
    out_args_ref=(exec --dangerously-bypass-approvals-and-sandbox -C "$WORKSPACE_ROOT" -)
  fi
}

bootstrap_prd_json() {
  local bootstrap_prompt bootstrap_output codex_args=()
  bootstrap_prompt=$(
    cat <<'EOF'
`scripts/ralph/prd.json` is missing or empty.

Use the `prd` skill to generate a concise PRD from current repository context, then use the `ralph` skill to convert it to `scripts/ralph/prd.json`.

Requirements:
- Produce valid JSON in `scripts/ralph/prd.json`
- Include: `project`, `branchName`, `description`, `userStories`
- Keep stories small and execution-ready for Ralph loop iterations
EOF
  )

  echo "PRD is missing/empty. Bootstrapping via Codex (prd + ralph skills)..."
  build_codex_exec_args codex_args
  bootstrap_output=$(printf '%s\n' "$bootstrap_prompt" | "$CODEX_BIN" "${codex_args[@]}" 2>&1) || true

  if echo "$bootstrap_output" | grep -qi "error"; then
    echo "Warning: bootstrap run reported errors; validating prd.json..."
  fi

  if is_prd_empty || ! prd_is_valid_json; then
    echo "PRD bootstrap failed: scripts/ralph/prd.json is still missing/empty/invalid JSON." >&2
    return 1
  fi

  echo "PRD bootstrap complete."
}

ensure_prd_ready() {
  if is_prd_empty; then
    if [ "$BOOTSTRAP_PRD" = "true" ]; then
      bootstrap_prd_json || return 1
    else
      echo "PRD file is missing or empty: $PRD_FILE" >&2
      echo "Create a PRD before running Ralph (then convert to scripts/ralph/prd.json)." >&2
      echo "Or rerun with --bootstrap-prd (or RALPH_BOOTSTRAP_PRD=1) to auto-bootstrap." >&2
      return 1
    fi
  fi

  if ! prd_is_valid_json; then
    echo "Invalid PRD JSON: $PRD_FILE" >&2
    return 1
  fi

  return 0
}

ensure_feature_branch_for_active_prd() {
  local feature_branch current_branch active_sprint sprint_branch base_branch
  feature_branch="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || true)"
  [ -n "$feature_branch" ] || return 0

  active_sprint="$(get_active_sprint || true)"
  if [ -n "$active_sprint" ]; then
    ensure_sprint_branch_exists "$active_sprint" || return 1
  fi

  if ! git show-ref --verify --quiet "refs/heads/$feature_branch"; then
    if [ -n "$active_sprint" ]; then
      sprint_branch="$(sprint_branch_name "$active_sprint")"
      git branch "$feature_branch" "$sprint_branch"
      echo "Created feature branch $feature_branch from sprint branch $sprint_branch."
    else
      base_branch="$(default_base_branch)"
      git branch "$feature_branch" "$base_branch"
      echo "Created feature branch $feature_branch from base branch $base_branch."
    fi
  fi

  current_branch="$(git branch --show-current)"
  if [ "$current_branch" != "$feature_branch" ]; then
    git checkout "$feature_branch" >/dev/null
    echo "Checked out feature branch: $feature_branch"
  fi
}

try_prime_prd() {
  if standalone_prd_is_active && prd_has_unfinished_stories; then
    echo "Standalone PRD is active with unfinished stories; skipping epic prime."
    return 0
  fi
  if standalone_prd_is_active && prd_all_passes && [ "$ALLOW_EPIC_FALLBACK" != "true" ]; then
    echo "Standalone PRD is complete. Refusing implicit epic fallback." >&2
    echo "Run ./scripts/ralph/ralph-commit.sh for standalone completion, then rerun with --allow-epic-fallback when ready." >&2
    return 1
  fi

  if [ ! -f "$PRIME_CMD" ]; then
    return 0
  fi

  bash "$PRIME_CMD" --auto
}

ensure_transient_files_not_tracked() {
  local tracked
  tracked="$(git ls-files -- "$PRD_FILE" "$PROGRESS_FILE" "$COMPLETION_STATE_FILE" || true)"
  if [ -n "$tracked" ]; then
    echo "Ralph transient files must not be git-tracked:" >&2
    printf '%s\n' "$tracked" >&2
    echo "Run: git rm --cached scripts/ralph/prd.json scripts/ralph/progress.txt scripts/ralph/.completion-state.json" >&2
    return 1
  fi
  return 0
}

ensure_no_transient_commits_in_range() {
  local from_ref="$1"
  local to_ref="$2"
  local leaked
  leaked="$(
    git log --name-only --pretty=format: "$from_ref..$to_ref" -- "$PRD_FILE" "$PROGRESS_FILE" "$COMPLETION_STATE_FILE" 2>/dev/null \
      | sed '/^$/d' \
      | sort -u || true
  )"
  if [ -n "$leaked" ]; then
    echo "Ralph transient files were committed during this iteration (disallowed):" >&2
    printf '%s\n' "$leaked" >&2
    echo "Do not use git add -f/--force for transient files." >&2
    echo "Repair with: git rm --cached scripts/ralph/prd.json scripts/ralph/progress.txt scripts/ralph/.completion-state.json" >&2
    return 1
  fi
  return 0
}

ensure_backlog_inputs_committed() {
  [ -n "${EPICS_FILE:-}" ] || return 0
  [ -f "$EPICS_FILE" ] || return 0

  local pending
  pending="$(git status --porcelain -- "$EPICS_FILE" || true)"
  if [ -n "$pending" ]; then
    echo "Commit epic backlog state before starting Ralph loop:" >&2
    printf '%s\n' "$pending" >&2
    echo "Required: commit active sprint epics.json changes first." >&2
    return 1
  fi
  return 0
}

infer_epic_id_from_prd_branch() {
  local prd_branch="$1"
  infer_epic_id_from_branch_path "$prd_branch"
}

ensure_epic_status_synced_with_prd() {
  local prd_branch epic_id epic_status active_epic_id

  [ -f "$EPICS_FILE" ] || return 0
  jq -e '.epics and (.epics|type=="array")' "$EPICS_FILE" >/dev/null 2>&1 || return 0
  prd_is_valid_json || return 0

  prd_branch="$(jq -r '.branchName // empty' "$PRD_FILE")"
  [ -n "$prd_branch" ] || return 0

  epic_id="$(infer_epic_id_from_prd_branch "$prd_branch" || true)"
  [ -n "$epic_id" ] || return 0

  if ! jq -e --arg id "$epic_id" '.epics[] | select(.id == $id)' "$EPICS_FILE" >/dev/null 2>&1; then
    echo "PRD branch $prd_branch does not map to an epic present in active sprint epics.json." >&2
    return 1
  fi

  epic_status="$(jq -r --arg id "$epic_id" '.epics[] | select(.id == $id) | .status // ""' "$EPICS_FILE")"
  active_epic_id="$(jq -r '.activeEpicId // empty' "$EPICS_FILE")"

  if prd_all_passes; then
    case "$epic_status" in
      done|abandoned|aborted)
        return 0
        ;;
      *)
        echo "PRD is complete but epic $epic_id is status '$epic_status'." >&2
        echo "Run ./scripts/ralph/ralph-commit.sh (or set status) before starting a new loop." >&2
        return 1
        ;;
    esac
  fi

  if prd_has_unfinished_stories; then
    if [ -n "$active_epic_id" ] && [ "$active_epic_id" != "$epic_id" ]; then
      echo "PRD is for $epic_id but active sprint epic is $active_epic_id." >&2
      echo "Re-prime the backlog state before starting the loop." >&2
      return 1
    fi
    case "$epic_status" in
      done|abandoned|aborted)
        echo "PRD has unfinished stories but epic $epic_id is status '$epic_status'." >&2
        echo "Re-prime or set the epic back to active/planned before loop start." >&2
        return 1
        ;;
      active)
        ;;
      *)
        echo "PRD has unfinished stories but epic $epic_id is status '$epic_status'." >&2
        echo "Re-prime the epic so sprint metadata and PRD state match before loop start." >&2
        return 1
        ;;
    esac
  fi

  return 0
}

require_cmd jq
require_cmd git
require_cmd sed
require_cmd tee
require_cmd awk
require_cmd find
require_cmd tr
require_cmd "$CODEX_BIN"
acquire_workflow_lock

if ! ensure_transient_files_not_tracked; then
  exit 1
fi

sync_active_prd_mode_with_current_prd

if ! resolve_sprint_paths; then
  exit 1
fi

if completion_is_stable; then
  echo "Ralph already has stable completion evidence; skipping loop."
  exit 0
fi

if ! ensure_epic_status_synced_with_prd; then
  exit 1
fi

# Guard before priming so auto-commit cannot absorb unrelated epics backlog edits.
if ! ensure_backlog_inputs_committed; then
  exit 1
fi

if ! try_prime_prd; then
  echo "Unable to prime PRD for next loop." >&2
  exit 1
fi

if ! ensure_prd_ready; then
  echo "Unable to initialize PRD file before Ralph loop: $PRD_FILE" >&2
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Ralph must be run inside a git repository." >&2
  echo "Tip: run from your project root (not from $SCRIPT_DIR)." >&2
  exit 1
fi

if ! [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]] || [ "$MAX_ITERATIONS" -lt 1 ]; then
  echo "Invalid max_iterations: $MAX_ITERATIONS" >&2
  exit 1
fi

if [ ! -f "$SCRIPT_DIR/prompt.md" ]; then
  echo "Missing prompt file: $SCRIPT_DIR/prompt.md" >&2
  exit 1
fi

if ! ensure_feature_branch_for_active_prd; then
  echo "Unable to prepare active feature branch for PRD execution." >&2
  exit 1
fi

if ! ensure_epic_status_synced_with_prd; then
  exit 1
fi

if ! require_previous_run_archived; then
  exit 1
fi

# Track current branch
if [ -f "$PRD_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  if [ -n "$CURRENT_BRANCH" ]; then
    echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
  fi
fi

# Initialize progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Ralph Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi
clear_completion_state

echo "Starting Ralph - Max iterations: $MAX_ITERATIONS"
echo "Workspace root: $WORKSPACE_ROOT"

for ((i=1; i<=MAX_ITERATIONS; i++)); do
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  Ralph Iteration $i of $MAX_ITERATIONS"
  echo "═══════════════════════════════════════════════════════"

  CODEX_ITER_TRANSCRIPT_FILE="$SCRIPT_DIR/.iteration-log-iter-$i.txt"
  ITERATION_START_HEAD="$(git rev-parse HEAD)"

  if ! ensure_prd_ready; then
    echo "Iteration $i aborted: PRD file is not ready."
    exit 1
  fi

  build_codex_exec_args CODEX_ARGS

  # Run Codex with the Ralph prompt (fresh context every iteration).
  # Avoid storing full model output in shell memory.
  set +e
  render_prompt | "$CODEX_BIN" "${CODEX_ARGS[@]}" 2>&1 | tee "$CODEX_ITER_TRANSCRIPT_FILE"
  CODEX_EXIT_CODE="${PIPESTATUS[1]:-1}"
  set -e

  cp -f "$CODEX_ITER_TRANSCRIPT_FILE" "$ITERATION_TRANSCRIPT_LATEST_FILE" >/dev/null 2>&1 || true
  write_iteration_handoff "$i" "$CODEX_ITER_TRANSCRIPT_FILE" "$CODEX_EXIT_CODE"

  ITERATION_END_HEAD="$(git rev-parse HEAD)"
  if [ "$ITERATION_START_HEAD" != "$ITERATION_END_HEAD" ]; then
    if ! ensure_no_transient_commits_in_range "$ITERATION_START_HEAD" "$ITERATION_END_HEAD"; then
      exit 1
    fi
    if ! ensure_explicit_scope_changes_valid "$ITERATION_START_HEAD" "$ITERATION_END_HEAD"; then
      exit 1
    fi
  fi

  if ! ensure_transient_files_not_tracked; then
    exit 1
  fi
  if ! ensure_explicit_scope_worktree_valid; then
    exit 1
  fi
  branch_name="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || true)"
  if strict_completion_ready; then
    finalize_wrapper_completion "$i" "$branch_name"
  elif latest_handoff_signals_completion && prd_all_passes && ! has_non_transient_worktree_changes; then
    write_completion_state "$i" "$branch_name"
  else
    clear_completion_state
  fi
  
  # Check for completion signal
  if completion_is_stable; then
    echo ""
    echo "Ralph completed all tasks!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    exit 0
  fi
  
  echo "Iteration $i complete. Continuing..."
  sleep 2
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
exit 1
