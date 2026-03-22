#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$WORKSPACE_ROOT" ]; then
  WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
SPRINTS_DIR="$SCRIPT_DIR/sprints"
TASKS_ROOT="$SCRIPT_DIR/tasks"
ARCHIVE_ROOT="$TASKS_ROOT/archive"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
SPRINT_BRANCH_PREFIX="ralph/sprint"
EDITOR_HELPER="$SCRIPT_DIR/lib/editor-intake.sh"
CODEX_BIN="${CODEX_BIN:-codex}"
LEGACY_ARCHIVE_DIR="$SCRIPT_DIR/archive"

# shellcheck source=./lib/editor-intake.sh
source "$EDITOR_HELPER"

usage() {
  cat <<'USAGE'
Usage: ./scripts/ralph/ralph-sprint.sh <command> [args]

Commands:
  list                              List available sprints
  create <sprint-name>              Create sprint structure and open iterative epic intake
  remove <sprint-name> [options]    Remove sprint (archive by default)
  use <sprint-name>                 Set active sprint
  branch <sprint-name>              Ensure sprint branch exists (ralph/sprint/<sprint-name>)
  status                            Show active sprint + readiness checks
  add-epic [sprint-name]            Add one epic using editor intake
  add-epics [sprint-name]           Interactive epic creation loop for sprint
  bootstrap-current <sprint-name>   Migrate current epic content into sprint structure
  -h, --help                        Show this help

Remove options:
  --hard                            Permanently delete sprint dirs instead of archiving
  --yes                             Skip confirmation prompt
  --drop-branch                     Delete sprint branch even if not merged
                                    (implied automatically by --hard)
USAGE
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing required command: $1"
  fi
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

build_codex_exec_args() {
  local -n out_args_ref="$1"
  if supports_codex_yolo; then
    out_args_ref=(--yolo exec -C "$WORKSPACE_ROOT" -)
  else
    out_args_ref=(exec --dangerously-bypass-approvals-and-sandbox -C "$WORKSPACE_ROOT" -)
  fi
}

generate_prd_markdown_from_intake_context() {
  local markdown_path="$1"
  local epic_id="$2"
  local sprint_name="$3"
  local title="$4"
  local goal="$5"
  local depends_csv="$6"
  local open_questions="$7"
  local prompt_context="$8"
  local sidecar prompt codex_args=()

  require_cmd "$CODEX_BIN"
  mkdir -p "$(dirname "$WORKSPACE_ROOT/$markdown_path")"

  sidecar="$(mktemp "$SCRIPT_DIR/.epic-intake-prompt-${epic_id}-XXXXXX.md")"
  cat > "$sidecar" <<EOF
# Epic Intake Context
epic_id: $epic_id
sprint: $sprint_name
title: $title
goal: $goal
depends_on: ${depends_csv:-none}
open_questions: ${open_questions:-none}

## Prompt Conversation
$prompt_context
EOF

  prompt=$(
    cat <<EOF
Use the \`prd\` skill.

Create a complete PRD markdown file at:
\`$markdown_path\`

Source context:
- Intake sidecar: \`${sidecar#$WORKSPACE_ROOT/}\`
- Epic ID: $epic_id
- Sprint: $sprint_name
- Title: $title
- Goal: $goal
- Depends on: ${depends_csv:-none}
- Open questions: ${open_questions:-none}

Requirements:
1. Write the PRD markdown to the exact destination path above.
2. Include execution-ready user stories with explicit acceptance criteria.
3. Keep stories dependency-ordered and implementable in small iterations.
4. If context has ambiguities, state assumptions explicitly in the markdown.

Return a short summary including the output path.
EOF
  )

  build_codex_exec_args codex_args
  if printf '%s\n' "$prompt" | "$CODEX_BIN" "${codex_args[@]}"; then
    rm -f "$sidecar"
    return 0
  fi

  echo "PRD generation failed for $epic_id. Prompt sidecar preserved at: $sidecar" >&2
  return 1
}

normalize_sprint_name() {
  local raw="$1"
  printf '%s' "$raw" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's|[^a-z0-9._-]+|-|g' \
    | sed -E 's|^-+||; s|-+$||'
}

sprint_epics_file() {
  local sprint="$1"
  printf '%s/sprints/%s/epics.json' "$SCRIPT_DIR" "$sprint"
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
  fail "Could not find base branch (master or main) for sprint branch creation."
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
  echo "Created sprint branch: $sprint_branch (from $base_branch)"
}

checkout_sprint_branch() {
  local sprint="$1"
  local sprint_branch
  sprint_branch="$(sprint_branch_name "$sprint")"
  git checkout "$sprint_branch" >/dev/null
  echo "Checked out sprint branch: $sprint_branch"
}

ensure_sprint_structure() {
  local sprint="$1"
  local epics_file
  epics_file="$(sprint_epics_file "$sprint")"

  mkdir -p "$SPRINTS_DIR/$sprint" "$TASKS_ROOT/$sprint" "$ARCHIVE_ROOT/$sprint"
  if [ ! -f "$epics_file" ]; then
    cat > "$epics_file" <<JSON
{
  "version": 1,
  "project": "$(basename "$WORKSPACE_ROOT")",
  "sprint": "$sprint",
  "capacityTarget": 8,
  "capacityCeiling": 10,
  "activeEpicId": null,
  "epics": []
}
JSON
  fi
}

get_active_sprint() {
  if [ -f "$ACTIVE_SPRINT_FILE" ]; then
    awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE"
    return 0
  fi
  return 1
}

legacy_archive_has_entries() {
  [ -d "$LEGACY_ARCHIVE_DIR" ] || return 1
  find "$LEGACY_ARCHIVE_DIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .
}

set_active_sprint() {
  local sprint="$1"
  echo "$sprint" > "$ACTIVE_SPRINT_FILE"
}

next_epic_id() {
  local epics_file="$1"
  local max_num
  max_num="$(jq -r '[.epics[]?.id | select(test("^EPIC-[0-9]{3}$")) | capture("^EPIC-(?<n>[0-9]{3})$").n | tonumber] | max // 0' "$epics_file")"
  printf 'EPIC-%03d' "$((max_num + 1))"
}

epic_num_from_id() {
  local epic_id="$1"
  if [[ "$epic_id" =~ ^EPIC-([0-9]{3})$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

render_epic_context() {
  local epics_file="$1"
  local rows
  rows="$(jq -r '
    .epics
    | sort_by(.priority, .id)
    | if length == 0 then
        "  (none yet)"
      else
        .[] | "  - \(.id) [p=\(.priority) status=\(.status // "planned")] \(.title)"
      end
  ' "$epics_file")"
  printf 'Existing epics:\n%s\n' "$rows"
}

validate_epic_dependencies() {
  local epics_file="$1"
  local id dep
  local -A exists=()

  while IFS= read -r id; do
    [ -n "$id" ] && exists["$id"]=1
  done < <(jq -r '.epics[].id' "$epics_file")

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      if [ "$dep" = "$id" ]; then
        fail "Epic $id cannot depend on itself."
      fi
      if [ -z "${exists[$dep]:-}" ]; then
        fail "Epic $id depends on missing epic: $dep"
      fi
    done < <(jq -r --arg id "$id" '.epics[] | select(.id == $id) | (.dependsOn // [])[]?' "$epics_file")
  done < <(jq -r '.epics[].id' "$epics_file")
}

validate_epic_dependency_cycles() {
  local epics_file="$1"
  local -A exists=()
  local -A state=()
  local -A deps_map=()
  local id

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    exists["$id"]=1
    deps_map["$id"]="$(jq -r --arg id "$id" '.epics[] | select(.id == $id) | (.dependsOn // []) | join(" ")' "$epics_file")"
  done < <(jq -r '.epics[].id' "$epics_file")

  dfs_cycle_check() {
    local node="$1"
    local dep
    case "${state[$node]:-0}" in
      1) fail "Dependency cycle detected at $node" ;;
      2) return 0 ;;
    esac

    state["$node"]=1
    for dep in ${deps_map[$node]:-}; do
      [ -n "${exists[$dep]:-}" ] || fail "Epic $node depends on missing epic: $dep"
      dfs_cycle_check "$dep"
    done
    state["$node"]=2
  }

  for id in "${!exists[@]}"; do
    dfs_cycle_check "$id"
  done
}

normalize_epics_file() {
  local epics_file="$1"
  local changed=1
  local iter=0
  local max_iter=200
  local id dep priority dep_priority max_dep_priority tmp_file

  validate_epic_dependencies "$epics_file"
  validate_epic_dependency_cycles "$epics_file"

  while [ "$changed" -eq 1 ]; do
    changed=0
    iter=$((iter + 1))
    [ "$iter" -le "$max_iter" ] || fail "Failed to normalize priorities after $max_iter iterations."

    while IFS= read -r id; do
      [ -n "$id" ] || continue
      priority="$(jq -r --arg id "$id" '.epics[] | select(.id == $id) | (.priority // 0)' "$epics_file")"
      max_dep_priority=0
      while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        dep_priority="$(jq -r --arg dep "$dep" '.epics[] | select(.id == $dep) | (.priority // 0)' "$epics_file")"
        if [ "$dep_priority" -gt "$max_dep_priority" ]; then
          max_dep_priority="$dep_priority"
        fi
      done < <(jq -r --arg id "$id" '.epics[] | select(.id == $id) | (.dependsOn // [])[]?' "$epics_file")

      if [ "$priority" -le "$max_dep_priority" ]; then
        tmp_file="$(mktemp)"
        jq --arg id "$id" --argjson newp "$((max_dep_priority + 1))" '
          .epics = (
            .epics
            | map(if .id == $id then .priority = $newp else . end)
          )
        ' "$epics_file" > "$tmp_file"
        mv "$tmp_file" "$epics_file"
        changed=1
      fi
    done < <(jq -r '.epics | sort_by(.priority, .id) | .[].id' "$epics_file")
  done

  tmp_file="$(mktemp)"
  jq '
    .epics = (
      .epics
      | sort_by(.priority, .id)
      | to_entries
      | map(.value + {priority: (.key + 1)})
    )
  ' "$epics_file" > "$tmp_file"
  mv "$tmp_file" "$epics_file"
}

append_epic_from_editor() {
  local sprint="$1"
  local epics_file="$2"
  local default_id default_num default_num_short
  local context template_path intake_text intake_file intake_block
  local epic_id title priority status depends_on prd_paths_input goal open_q prompt_context
  local deps_lines resolved_prd_lines deps_json prd_json_paths open_q_json prompt_context_json tmp_file
  local primary_prd_path missing_prd_paths prd_path depends_csv

  default_id="$(next_epic_id "$epics_file")"
  default_num="$(epic_num_from_id "$default_id" || true)"
  default_num_short="$(printf '%s' "${default_num:-001}" | sed -E 's|^0+||')"
  [ -n "$default_num_short" ] || default_num_short="1"
  context="$(render_epic_context "$epics_file")"
  template_path="$SCRIPT_DIR/templates/epic-intake.md"
  [ -f "$template_path" ] || fail "Missing template: $template_path"

  intake_text="$({
    sed \
      -e "s|{{DEFAULT_EPIC_ID}}|$default_id|g" \
      -e "s|{{DEFAULT_PRIORITY}}|$(jq '.epics | length + 1' "$epics_file")|g" \
      -e "s|{{SPRINT_NAME}}|$sprint|g" \
      -e "s|{{EPIC_NUM_LOWER}}|$default_num_short|g" \
      "$template_path"
    echo
    echo "# Existing Epics Snapshot"
    echo "$context"
  } )"

  intake_file="$(mktemp)"
  printf '%s\n' "$intake_text" > "$intake_file"
  run_editor_on_file "$intake_file"
  intake_block="$(extract_marked_block "$intake_file" "<!-- BEGIN INPUT -->" "<!-- END INPUT -->")"
  rm -f "$intake_file"

  epic_id="$(printf '%s\n' "$intake_block" | kv_from_block "EPIC_ID" | trim_whitespace)"
  title="$(printf '%s\n' "$intake_block" | kv_from_block "TITLE" | trim_whitespace)"
  priority="$(printf '%s\n' "$intake_block" | kv_from_block "PRIORITY" | trim_whitespace)"
  local effort
  effort="$(printf '%s\n' "$intake_block" | kv_from_block "EFFORT" | trim_whitespace)"
  status="$(printf '%s\n' "$intake_block" | kv_from_block "STATUS" | trim_whitespace)"
  depends_on="$(printf '%s\n' "$intake_block" | kv_from_block "DEPENDS_ON" | trim_whitespace)"
  prd_paths_input="$(printf '%s\n' "$intake_block" | kv_from_block "PRD_PATHS" | trim_whitespace)"
  goal="$(printf '%s\n' "$intake_block" | kv_from_block "GOAL" | trim_whitespace)"
  open_q="$(printf '%s\n' "$intake_block" | kv_from_block "OPEN_QUESTION" | trim_whitespace)"
  prompt_context="$({
    printf '%s\n' "$intake_block" | awk '
      /^PROMPT_CONTEXT:/ {
        line=$0
        sub(/^PROMPT_CONTEXT:[[:space:]]*/, "", line)
        if (length(line) > 0) print line
        in_section=1
        next
      }
      in_section {print}
    '
  })"

  [ -n "$epic_id" ] || epic_id="$default_id"
  [ -n "$status" ] || status="planned"
  [ -n "$priority" ] || priority="$(jq '.epics | length + 1' "$epics_file")"
  [ -n "$effort" ] || effort="3"
  [ -n "$open_q" ] || open_q="None currently."
  [ -n "$prompt_context" ] || fail "PROMPT_CONTEXT is required to generate PRD task markdown."

  if ! [[ "$epic_id" =~ ^EPIC-[0-9]{3}$ ]]; then
    fail "Invalid epic ID format. Use EPIC-###."
  fi
  if jq -e --arg id "$epic_id" '.epics[] | select(.id == $id)' "$epics_file" >/dev/null 2>&1; then
    fail "Epic already exists: $epic_id"
  fi
  [ -n "$title" ] || fail "Title is required."
  [[ "$priority" =~ ^[0-9]+$ ]] || fail "Priority must be numeric."
  [[ "$effort" =~ ^(1|2|3|5)$ ]] || fail "Effort must be one of: 1, 2, 3, 5."
  [ -n "$goal" ] || fail "Goal is required."
  [ -n "$prd_paths_input" ] || fail "At least one PRD path is required."

  case "$status" in
    planned|ready|blocked|active|done|abandoned)
      ;;
    *)
      fail "Invalid status."
      ;;
  esac

  deps_lines="$({
    printf '%s\n' "$depends_on" \
      | tr ',' '\n' \
      | trim_whitespace \
      | awk 'NF {print}'
  })"

  if printf '%s\n' "$deps_lines" | grep -qx "$epic_id"; then
    fail "Epic $epic_id cannot depend on itself."
  fi

  if [ -n "$deps_lines" ]; then
    local dep missing_deps=""
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      if ! jq -e --arg id "$dep" '.epics[] | select(.id == $id)' "$epics_file" >/dev/null 2>&1; then
        missing_deps+="$dep"$'\n'
      fi
    done <<< "$deps_lines"
    if [ -n "$missing_deps" ]; then
      fail "$(printf 'Unknown dependency IDs:\n%s' "$missing_deps")"
    fi
  fi

  resolved_prd_lines="$({
    printf '%s\n' "$prd_paths_input" \
      | tr ',' '\n' \
      | trim_whitespace \
      | awk 'NF {print}' \
      | while IFS= read -r p; do
          if [[ "$p" == */* ]]; then
            printf '%s\n' "$p"
          else
            printf 'scripts/ralph/tasks/%s/%s\n' "$sprint" "$p"
          fi
        done
  })"

  primary_prd_path="$(printf '%s\n' "$resolved_prd_lines" | awk 'NF {print; exit}')"
  [ -n "$primary_prd_path" ] || fail "At least one PRD path is required."
  depends_csv="$(printf '%s\n' "$deps_lines" | paste -sd ', ' -)"
  generate_prd_markdown_from_intake_context \
    "$primary_prd_path" \
    "$epic_id" \
    "$sprint" \
    "$title" \
    "$goal" \
    "$depends_csv" \
    "$open_q" \
    "$prompt_context" || fail "Failed to generate PRD markdown for $epic_id"

  [ -s "$WORKSPACE_ROOT/$primary_prd_path" ] || fail "Generated PRD file missing or empty: $primary_prd_path"
  missing_prd_paths=""
  while IFS= read -r prd_path; do
    [ -n "$prd_path" ] || continue
    if [ ! -s "$WORKSPACE_ROOT/$prd_path" ]; then
      missing_prd_paths+="$prd_path"$'\n'
    fi
  done <<< "$resolved_prd_lines"
  if [ -n "$missing_prd_paths" ]; then
    fail "$(printf 'Missing PRD paths after generation:\n%s' "$missing_prd_paths")"
  fi

  deps_json="$(printf '%s\n' "$deps_lines" | lines_to_json_array)"
  prd_json_paths="$(printf '%s\n' "$resolved_prd_lines" | lines_to_json_array)"
  open_q_json="$(jq -Rn --arg q "$open_q" '[$q]')"
  prompt_context_json="$(jq -Rn --arg p "$prompt_context" '$p')"

  tmp_file="$(mktemp)"
  jq --arg id "$epic_id" \
    --arg title "$title" \
    --argjson priority "$priority" \
    --argjson effort "$effort" \
    --arg status "$status" \
    --arg planningSource "local" \
    --arg goal "$goal" \
    --argjson dependsOn "$deps_json" \
    --argjson prdPaths "$prd_json_paths" \
    --argjson openQuestions "$open_q_json" \
    --argjson promptContext "$prompt_context_json" '
      .epics += [{
        id: $id,
        title: $title,
        priority: $priority,
        effort: $effort,
        status: $status,
        planningSource: $planningSource,
        dependsOn: $dependsOn,
        prdPaths: $prdPaths,
        goal: $goal,
        openQuestions: $openQuestions,
        promptContext: $promptContext
      }]
    ' "$epics_file" > "$tmp_file"
  mv "$tmp_file" "$epics_file"

  normalize_epics_file "$epics_file"
  echo "Added epic $epic_id to $sprint."
}

add_epics_loop() {
  local sprint="$1"
  local epics_file
  epics_file="$(sprint_epics_file "$sprint")"
  [ -f "$epics_file" ] || fail "Missing sprint epics file: $epics_file"
  [ -t 0 ] || fail "add-epics requires interactive terminal input."

  while true; do
    read -r -p "Create another epic for $sprint? [y/N]: " reply
    case "${reply,,}" in
      y|yes)
        append_epic_from_editor "$sprint" "$epics_file"
        ;;
      *)
        break
        ;;
    esac
  done
}

add_single_epic() {
  local sprint="$1"
  local epics_file
  epics_file="$(sprint_epics_file "$sprint")"
  [ -f "$epics_file" ] || fail "Missing sprint epics file: $epics_file"
  append_epic_from_editor "$sprint" "$epics_file"
}

readiness_status() {
  local sprint="$1"
  local epics_file
  local sprint_branch current_branch
  local capacity_target capacity_ceiling planned_effort
  epics_file="$(sprint_epics_file "$sprint")"
  sprint_branch="$(sprint_branch_name "$sprint")"
  current_branch="$(git branch --show-current)"

  if [ ! -f "$epics_file" ]; then
    fail "Missing sprint epics file: $epics_file"
  fi
  jq -e '.epics and (.epics|type=="array")' "$epics_file" >/dev/null 2>&1 || fail "Invalid JSON: $epics_file"

  echo "Active sprint: $sprint"
  echo "Epics file: $epics_file"
  echo "Epic count: $(jq '.epics | length' "$epics_file")"
  capacity_target="$(jq -r '.capacityTarget // 8' "$epics_file")"
  capacity_ceiling="$(jq -r '.capacityCeiling // 10' "$epics_file")"
  planned_effort="$(jq -r '[.epics[]?.effort // 0] | add // 0' "$epics_file")"
  echo "Sprint capacity: target=$capacity_target ceiling=$capacity_ceiling planned=$planned_effort"
  if [ "$planned_effort" -gt "$capacity_ceiling" ]; then
    echo "Capacity warning: planned effort exceeds sprint ceiling."
  fi
  if git show-ref --verify --quiet "refs/heads/$sprint_branch"; then
    echo "Sprint branch: $sprint_branch (exists)"
  else
    echo "Sprint branch: $sprint_branch (missing)"
  fi
  echo "Current branch: $current_branch"
  if legacy_archive_has_entries; then
    echo "Legacy archive drift detected: $LEGACY_ARCHIVE_DIR still contains files."
    echo "Canonical Ralph archives live under: $TASKS_ROOT/archive"
  fi

  local active_epic_id active_epic_line
  active_epic_id="$(jq -r '.activeEpicId // empty' "$epics_file")"
  if [ -n "$active_epic_id" ]; then
    active_epic_line="$(jq -r --arg id "$active_epic_id" '
      .epics[]
      | select(.id == $id)
      | "Active epic: \(.id) (P\(.priority) E\(.effort // 0)) - \(.title)\nStatus: \(.status)\nDependsOn: \((.dependsOn // []) | join(", "))"
    ' "$epics_file")"
    if [ -n "$active_epic_line" ]; then
      echo "$active_epic_line"
    else
      echo "Active epic: $active_epic_id (missing from epics list)"
    fi
  else
    echo "Active epic: (none)"
  fi

  local missing_paths
  local missing_paths_blocking
  local missing_paths_generatable
  missing_paths="$(jq -r '.epics[]? | .id as $id | (.promptContext // "") as $ctx | .prdPaths[]? | [$id, ., ($ctx|gsub("[\r\n\t]";" "))] | @tsv' "$epics_file" \
    | while IFS=$'\t' read -r epic_id prd_path prompt_ctx; do
        [ -n "$prd_path" ] || continue
        [ -f "$WORKSPACE_ROOT/$prd_path" ] && continue
        if [ -n "$prompt_ctx" ]; then
          printf 'GENERATABLE\t%s\t%s\n' "$epic_id" "$prd_path"
        else
          printf 'BLOCKING\t%s\t%s\n' "$epic_id" "$prd_path"
        fi
      done)"
  missing_paths_blocking="$(printf '%s\n' "$missing_paths" | awk -F '\t' '$1=="BLOCKING"{print $2": "$3}')"
  missing_paths_generatable="$(printf '%s\n' "$missing_paths" | awk -F '\t' '$1=="GENERATABLE"{print $2": "$3}')"
  if [ -n "$missing_paths_generatable" ]; then
    echo "PRD paths pending generation (available via promptContext):"
    printf '%s\n' "$missing_paths_generatable"
  fi
  if [ -n "$missing_paths_blocking" ]; then
    echo "Missing PRD paths (blocking):"
    printf '%s\n' "$missing_paths_blocking"
    exit 1
  fi

  local next_output
  local active_prd_mode active_epic_status
  active_prd_mode=""
  active_epic_status=""
  if [ -f "$SCRIPT_DIR/.active-prd" ]; then
    active_prd_mode="$(jq -r '.mode // empty' "$SCRIPT_DIR/.active-prd" 2>/dev/null || true)"
  fi
  if [ -n "$active_epic_id" ]; then
    active_epic_status="$(jq -r --arg id "$active_epic_id" '.epics[] | select(.id == $id) | (.status // "")' "$epics_file" 2>/dev/null || true)"
  fi
  if next_output="$(RALPH_EPICS_FILE="$epics_file" "$SCRIPT_DIR/ralph-epic.sh" next 2>/dev/null)"; then
    echo "$next_output"
  else
    echo "No eligible next epic."
  fi
  if [ "$active_prd_mode" = "epic" ] && [ -f "$SCRIPT_DIR/prd.json" ] \
     && jq -e '(.userStories | length) > 0 and all(.userStories[]; .passes == true)' "$SCRIPT_DIR/prd.json" >/dev/null 2>&1; then
    echo "Next action: run ./scripts/ralph/ralph-commit.sh to finish the completed epic."
  elif [ -n "$active_epic_id" ] && [ "$active_epic_status" = "active" ]; then
    echo "Next action: run ./scripts/ralph/ralph.sh to continue the active epic."
  else
    echo "Next action: run ./scripts/ralph/ralph-prime.sh to activate the next epic."
  fi
}

bootstrap_current() {
  local sprint_raw="$1"
  local sprint
  sprint="$(normalize_sprint_name "$sprint_raw")"
  [ -n "$sprint" ] || fail "Invalid sprint name."

  local old_epics="$SCRIPT_DIR/epics.json"
  local new_epics
  new_epics="$(sprint_epics_file "$sprint")"

  if [ ! -f "$old_epics" ]; then
    if [ -f "$new_epics" ] && jq -e '.epics and (.epics | type == "array")' "$new_epics" >/dev/null 2>&1; then
      set_active_sprint "$sprint"
      echo "No legacy scripts/ralph/epics.json found. Sprint layout is already in use."
      echo "Active sprint set to: $sprint"
      return 0
    fi
    fail "Missing source epics file: $old_epics"
  fi

  ensure_sprint_structure "$sprint"

  if [ -f "$new_epics" ] && [ "$(jq '.epics | length' "$new_epics")" -gt 0 ]; then
    fail "Target sprint already has epics: $new_epics"
  fi

  local epic_file
  for epic_file in \
    "$SCRIPT_DIR"/tasks/prd-epic-*.md \
    "$WORKSPACE_ROOT"/tasks/prd-epic-*.md
  do
    [ -f "$epic_file" ] || continue
    mv "$epic_file" "$TASKS_ROOT/$sprint/"
  done

  if [ -d "$SCRIPT_DIR/archive" ]; then
    shopt -s dotglob nullglob
    local item
    for item in "$SCRIPT_DIR"/archive/*; do
      [ -e "$item" ] || continue
      mv "$item" "$ARCHIVE_ROOT/$sprint/"
    done
    shopt -u dotglob nullglob
    rmdir "$SCRIPT_DIR/archive" 2>/dev/null || true
  fi
  if [ -d "$TASKS_ROOT/archive" ]; then
    shopt -s dotglob nullglob
    local item
    for item in "$TASKS_ROOT"/archive/*; do
      [ -e "$item" ] || continue
      case "$(basename "$item")" in
        "$sprint"|prds|sprints)
          continue
          ;;
      esac
      mv "$item" "$ARCHIVE_ROOT/$sprint/"
    done
    shopt -u dotglob nullglob
  fi

  mv "$old_epics" "$new_epics"

  local tmp_file
  tmp_file="$(mktemp)"
  jq --arg sprint "$sprint" '
    .epics = (
      .epics
      | map(
          .prdPaths = (
            (.prdPaths // [])
            | map(
                if test("^tasks/prd-epic-") or test("^scripts/ralph/tasks/prd-epic-") then
                  "scripts/ralph/tasks/" + $sprint + "/" + (split("/") | .[-1])
                else
                  .
                end
              )
          )
        )
    )
  ' "$new_epics" > "$tmp_file"
  mv "$tmp_file" "$new_epics"

  set_active_sprint "$sprint"
  ensure_sprint_branch_exists "$sprint"
  checkout_sprint_branch "$sprint"
  echo "Bootstrapped current Ralph content into sprint: $sprint"
  echo "Active sprint set to: $sprint"
}

cmd_create() {
  local sprint

  [ $# -eq 1 ] || fail "Usage: create <sprint-name>"
  sprint="$(normalize_sprint_name "$1")"
  [ -n "$sprint" ] || fail "Invalid sprint name."

  ensure_sprint_structure "$sprint"
  ensure_sprint_branch_exists "$sprint"
  set_active_sprint "$sprint"
  echo "Created sprint: $sprint"
  echo "Active sprint set to: $sprint"
  checkout_sprint_branch "$sprint"

  if [ -t 0 ]; then
    add_epics_loop "$sprint"
  fi
}

confirm_action() {
  local prompt="$1"
  local assume_yes="${2:-0}"
  local reply
  if [ "$assume_yes" -eq 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    fail "Confirmation required in non-interactive mode. Re-run with --yes."
  fi
  read -r -p "$prompt [y/N]: " reply
  case "${reply,,}" in
    y|yes) return 0 ;;
    *) fail "Aborted." ;;
  esac
}

remove_sprint() {
  local sprint_raw="$1"
  shift
  local sprint hard_delete assume_yes drop_branch
  local epics_file sprint_dir tasks_dir archive_dir stamp sprint_branch base_branch active

  sprint="$(normalize_sprint_name "$sprint_raw")"
  [ -n "$sprint" ] || fail "Invalid sprint name."

  hard_delete=0
  assume_yes=0
  drop_branch=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --hard)
        hard_delete=1
        drop_branch=1
        ;;
      --yes)
        assume_yes=1
        ;;
      --drop-branch)
        drop_branch=1
        ;;
      *)
        fail "Unknown remove option: $1"
        ;;
    esac
    shift
  done

  epics_file="$(sprint_epics_file "$sprint")"
  sprint_dir="$SPRINTS_DIR/$sprint"
  tasks_dir="$TASKS_ROOT/$sprint"
  [ -f "$epics_file" ] || fail "Sprint does not exist: $sprint"

  active="$(get_active_sprint || true)"
  if [ "$active" = "$sprint" ]; then
    confirm_action "Sprint $sprint is active. Remove and clear active sprint?" "$assume_yes"
    rm -f "$ACTIVE_SPRINT_FILE"
  else
    if [ "$hard_delete" -eq 1 ]; then
      confirm_action "Permanently delete sprint $sprint?" "$assume_yes"
    else
      confirm_action "Archive and remove sprint $sprint?" "$assume_yes"
    fi
  fi

  if [ "$hard_delete" -eq 1 ]; then
    rm -rf "$sprint_dir" "$tasks_dir"
    echo "Removed sprint directories permanently: $sprint"
  else
    stamp="$(date +%F)-${sprint}-removed"
    archive_dir="$ARCHIVE_ROOT/sprints/$stamp"
    if [ -e "$archive_dir" ]; then
      archive_dir="${archive_dir}-$(date +%H%M%S)"
    fi
    mkdir -p "$archive_dir"
    [ -d "$sprint_dir" ] && mv "$sprint_dir" "$archive_dir/sprint-def"
    [ -d "$tasks_dir" ] && mv "$tasks_dir" "$archive_dir/sprint-tasks"
    cat > "$archive_dir/archive-manifest.txt" <<EOF
action=remove-sprint
sprint=$sprint
removed_at=$(date -Iseconds)
source_sprint_dir=$sprint_dir
source_tasks_dir=$tasks_dir
EOF
    echo "Archived sprint to: $archive_dir"
  fi

  sprint_branch="$(sprint_branch_name "$sprint")"
  if git show-ref --verify --quiet "refs/heads/$sprint_branch"; then
    if [ "$drop_branch" -eq 1 ]; then
      if [ "$(git branch --show-current)" = "$sprint_branch" ]; then
        base_branch="$(default_base_branch)"
        git checkout "$base_branch" >/dev/null
      fi
      git branch -D "$sprint_branch" >/dev/null
      echo "Deleted sprint branch: $sprint_branch"
    else
      base_branch="$(default_base_branch)"
      if git merge-base --is-ancestor "$sprint_branch" "$base_branch"; then
        if [ "$(git branch --show-current)" = "$sprint_branch" ]; then
          git checkout "$base_branch" >/dev/null
        fi
        git branch -d "$sprint_branch" >/dev/null
        echo "Deleted merged sprint branch: $sprint_branch"
      else
        echo "Kept unmerged sprint branch: $sprint_branch (use --drop-branch to force delete)"
      fi
    fi
  fi
}

main() {
  require_cmd git
  require_cmd jq
  require_cmd sed
  require_cmd tr

  local cmd="${1:-}"
  case "$cmd" in
    list)
      if [ -d "$SPRINTS_DIR" ]; then
        find "$SPRINTS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
      fi
      ;;
    create)
      shift
      cmd_create "$@"
      ;;
    remove)
      [ $# -ge 2 ] || fail "Usage: remove <sprint-name> [--hard] [--yes] [--drop-branch]"
      remove_sprint "$2" "${@:3}"
      ;;
    use)
      [ $# -eq 2 ] || fail "Usage: use <sprint-name>"
      local sprint
      sprint="$(normalize_sprint_name "$2")"
      [ -f "$(sprint_epics_file "$sprint")" ] || fail "Sprint does not exist: $sprint"
      ensure_sprint_branch_exists "$sprint"
      set_active_sprint "$sprint"
      echo "Active sprint set to: $sprint"
      checkout_sprint_branch "$sprint"
      ;;
    branch)
      [ $# -eq 2 ] || fail "Usage: branch <sprint-name>"
      local sprint
      sprint="$(normalize_sprint_name "$2")"
      [ -f "$(sprint_epics_file "$sprint")" ] || fail "Sprint does not exist: $sprint"
      ensure_sprint_branch_exists "$sprint"
      ;;
    status)
      local active
      active="$(get_active_sprint || true)"
      [ -n "$active" ] || fail "No active sprint set."
      readiness_status "$active"
      ;;
    add-epic)
      local target
      target="${2:-$(get_active_sprint || true)}"
      [ -n "$target" ] || fail "No sprint provided and no active sprint set."
      [ -f "$(sprint_epics_file "$target")" ] || fail "Sprint does not exist: $target"
      add_single_epic "$target"
      ;;
    add-epics)
      local target
      target="${2:-$(get_active_sprint || true)}"
      [ -n "$target" ] || fail "No sprint provided and no active sprint set."
      [ -f "$(sprint_epics_file "$target")" ] || fail "Sprint does not exist: $target"
      add_epics_loop "$target"
      ;;
    bootstrap-current)
      [ $# -eq 2 ] || fail "Usage: bootstrap-current <sprint-name>"
      bootstrap_current "$2"
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      fail "Unknown command: $cmd"
      ;;
  esac
}

main "$@"
