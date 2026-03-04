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

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/ralph-sprint.sh <command> [args]

Commands:
  list                              List available sprints
  create <sprint-name>              Create sprint structure and interactive epic-entry loop
  use <sprint-name>                 Set active sprint
  status                            Show active sprint + readiness checks
  add-epics [sprint-name]           Interactive epic creation loop for sprint
  bootstrap-current <sprint-name>   Migrate current epic content into sprint structure
  -h, --help                        Show this help
EOF
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

ensure_sprint_structure() {
  local sprint="$1"
  local epics_file
  epics_file="$(sprint_epics_file "$sprint")"

  mkdir -p "$SPRINTS_DIR/$sprint" "$TASKS_ROOT/$sprint" "$ARCHIVE_ROOT/$sprint"
  if [ ! -f "$epics_file" ]; then
    cat > "$epics_file" <<EOF
{
  "version": 1,
  "project": "$(basename "$WORKSPACE_ROOT")",
  "activeEpicId": null,
  "epics": []
}
EOF
  fi
}

get_active_sprint() {
  if [ -f "$ACTIVE_SPRINT_FILE" ]; then
    awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE"
    return 0
  fi
  return 1
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

append_epic_interactive() {
  local sprint="$1"
  local epics_file="$2"
  local default_id epic_id title priority status depends_on goal prd_paths_input prd_json_paths open_q
  local deps_lines resolved_prd_lines
  local open_q_json

  default_id="$(next_epic_id "$epics_file")"

  read -r -p "Epic ID [$default_id]: " epic_id
  epic_id="${epic_id:-$default_id}"
  if ! [[ "$epic_id" =~ ^EPIC-[0-9]{3}$ ]]; then
    fail "Invalid epic ID format. Use EPIC-###."
  fi
  if jq -e --arg id "$epic_id" '.epics[] | select(.id == $id)' "$epics_file" >/dev/null 2>&1; then
    fail "Epic already exists: $epic_id"
  fi

  read -r -p "Title: " title
  [ -n "$title" ] || fail "Title is required."

  read -r -p "Priority (number): " priority
  [[ "$priority" =~ ^[0-9]+$ ]] || fail "Priority must be numeric."

  read -r -p "Status [planned]: " status
  status="${status:-planned}"
  case "$status" in
    planned|ready|blocked|active|done|abandoned)
      ;;
    *)
      fail "Invalid status."
      ;;
  esac

  read -r -p "Depends on (comma-separated EPIC IDs, optional): " depends_on
  read -r -p "Goal: " goal
  [ -n "$goal" ] || fail "Goal is required."
  read -r -p "PRD paths or filenames (comma-separated): " prd_paths_input
  [ -n "$prd_paths_input" ] || fail "At least one PRD path is required."
  read -r -p "Open question (optional, leave blank for none): " open_q

  deps_lines="$(
    printf '%s\n' "$depends_on" \
      | tr ',' '\n' \
      | sed -E 's|^[[:space:]]+||; s|[[:space:]]+$||' \
      | awk 'NF {print}'
  )"
  if [ -n "$deps_lines" ]; then
    local dep missing_deps=""
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      if [ "$dep" = "$epic_id" ]; then
        fail "Epic $epic_id cannot depend on itself."
      fi
      if ! jq -e --arg id "$dep" '.epics[] | select(.id == $id)' "$epics_file" >/dev/null 2>&1; then
        missing_deps+="$dep"$'\n'
      fi
    done <<< "$deps_lines"
    if [ -n "$missing_deps" ]; then
      fail "$(printf 'Unknown dependency IDs:\n%s' "$missing_deps")"
    fi
  fi

  resolved_prd_lines="$(
    printf '%s\n' "$prd_paths_input" \
      | tr ',' '\n' \
      | sed -E 's|^[[:space:]]+||; s|[[:space:]]+$||' \
      | awk 'NF {print}' \
      | while IFS= read -r p; do
          if [[ "$p" == */* ]]; then
            printf '%s\n' "$p"
          else
            printf 'scripts/ralph/tasks/%s/%s\n' "$sprint" "$p"
          fi
        done
  )"
  local missing_prd_paths=""
  local prd_path
  while IFS= read -r prd_path; do
    [ -n "$prd_path" ] || continue
    if [ ! -f "$WORKSPACE_ROOT/$prd_path" ]; then
      missing_prd_paths+="$prd_path"$'\n'
    fi
  done <<< "$resolved_prd_lines"
  if [ -n "$missing_prd_paths" ]; then
    fail "$(printf 'Missing PRD paths (create files first):\n%s' "$missing_prd_paths")"
  fi

  prd_json_paths="$(
    printf '%s\n' "$resolved_prd_lines" \
      | jq -Rsc 'split("\n") | map(select(length > 0))'
  )"

  open_q_json="$(jq -Rn --arg q "$open_q" '$q | if length > 0 then [$q] else ["None currently."] end')"

  local deps_json
  deps_json="$(
    printf '%s\n' "$deps_lines" \
      | jq -Rsc 'split("\n") | map(select(length > 0))'
  )"

  local tmp_file
  tmp_file="$(mktemp)"
  jq --arg id "$epic_id" \
    --arg title "$title" \
    --argjson priority "$priority" \
    --arg status "$status" \
    --arg goal "$goal" \
    --argjson dependsOn "$deps_json" \
    --argjson prdPaths "$prd_json_paths" \
    --argjson openQuestions "$open_q_json" '
      .epics += [{
        id: $id,
        title: $title,
        priority: $priority,
        status: $status,
        dependsOn: $dependsOn,
        prdPaths: $prdPaths,
        goal: $goal,
        openQuestions: $openQuestions
      }]
      | .epics |= sort_by(.priority, .id)
    ' "$epics_file" > "$tmp_file"
  mv "$tmp_file" "$epics_file"
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
        append_epic_interactive "$sprint" "$epics_file"
        ;;
      *)
        break
        ;;
    esac
  done
}

readiness_status() {
  local sprint="$1"
  local epics_file
  epics_file="$(sprint_epics_file "$sprint")"

  if [ ! -f "$epics_file" ]; then
    fail "Missing sprint epics file: $epics_file"
  fi
  jq -e '.epics and (.epics|type=="array")' "$epics_file" >/dev/null 2>&1 || fail "Invalid JSON: $epics_file"

  echo "Active sprint: $sprint"
  echo "Epics file: $epics_file"
  echo "Epic count: $(jq '.epics | length' "$epics_file")"

  local missing_paths
  missing_paths="$(jq -r '.epics[]?.prdPaths[]?' "$epics_file" | while IFS= read -r p; do [ -n "$p" ] || continue; [ -f "$WORKSPACE_ROOT/$p" ] || echo "$p"; done)"
  if [ -n "$missing_paths" ]; then
    echo "Missing PRD paths:"
    printf '%s\n' "$missing_paths"
    exit 1
  fi

  local next_output
  if next_output="$(RALPH_EPICS_FILE="$epics_file" "$SCRIPT_DIR/ralph-epic.sh" next 2>/dev/null)"; then
    echo "$next_output"
  else
    echo "No eligible next epic."
  fi
  echo "Sprint is ready for ralph-prime."
}

bootstrap_current() {
  local sprint_raw="$1"
  local sprint
  sprint="$(normalize_sprint_name "$sprint_raw")"
  [ -n "$sprint" ] || fail "Invalid sprint name."

  local old_epics="$SCRIPT_DIR/epics.json"
  local new_epics
  new_epics="$(sprint_epics_file "$sprint")"

  # In already-migrated repos, bootstrap-current should no-op with a clear status.
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

  # Move only epic task files into sprint task dir.
  local epic_file
  for epic_file in "$WORKSPACE_ROOT"/tasks/prd-epic-*.md; do
    [ -f "$epic_file" ] || continue
    mv "$epic_file" "$TASKS_ROOT/$sprint/"
  done

  # Move current archive content into sprint archive dir.
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
                if test("^tasks/prd-epic-") then
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
  echo "Bootstrapped current Ralph content into sprint: $sprint"
  echo "Active sprint set to: $sprint"
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
      [ $# -eq 2 ] || fail "Usage: create <sprint-name>"
      local sprint
      sprint="$(normalize_sprint_name "$2")"
      [ -n "$sprint" ] || fail "Invalid sprint name."
      ensure_sprint_structure "$sprint"
      set_active_sprint "$sprint"
      echo "Created sprint: $sprint"
      echo "Active sprint set to: $sprint"
      if [ -t 0 ]; then
        add_epics_loop "$sprint"
      fi
      ;;
    use)
      [ $# -eq 2 ] || fail "Usage: use <sprint-name>"
      [ -f "$(sprint_epics_file "$2")" ] || fail "Sprint does not exist: $2"
      set_active_sprint "$2"
      echo "Active sprint set to: $2"
      ;;
    status)
      local active
      active="$(get_active_sprint || true)"
      [ -n "$active" ] || fail "No active sprint set."
      readiness_status "$active"
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
