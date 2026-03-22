#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPRINTS_DIR="$SCRIPT_DIR/sprints"
ACTIVE_SPRINT_FILE="$SCRIPT_DIR/.active-sprint"
EPICS_FILE="${RALPH_EPICS_FILE:-}"

get_active_sprint() {
  if [ -f "$ACTIVE_SPRINT_FILE" ]; then
    awk 'NF {print; exit}' "$ACTIVE_SPRINT_FILE"
    return 0
  fi
  return 1
}

resolve_epics_file() {
  if [ -n "$EPICS_FILE" ]; then
    return 0
  fi

  local active_sprint
  active_sprint="$(get_active_sprint || true)"
  if [ -z "$active_sprint" ]; then
    fail "No active sprint. Use ./scripts/ralph/ralph-sprint.sh use <sprint-name>."
  fi

  EPICS_FILE="$SPRINTS_DIR/$active_sprint/epics.json"
}

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/ralph-epic.sh <command> [args]

Commands:
  list                      List all epics ordered by priority
  add --title <TEXT> [options]
                            Add an epic non-interactively
  next                      Show the next eligible epic
  next-id                   Print only the next eligible epic ID
  start-next                Mark next eligible epic as active
  set-status <ID> <STATUS>  Set epic status (planned|ready|blocked|active|done|abandoned)
  normalize-statuses        Convert legacy status 'aborted' to 'abandoned'
  abandon <ID> [REASON]     Mark epic as abandoned (kept for historical reference)
  remove <ID>               Remove an abandoned epic from active sprint epics.json
  show <ID>                 Show full epic JSON

Eligibility for "next":
  - status is ready or planned
  - all dependencies are status=done
  - lowest priority wins, then ID

Add options:
  --id EPIC-XXX             Explicit epic ID (default: next sequential ID)
  --title TEXT              Epic title (required)
  --priority N              Priority integer (default: next available)
  --effort N                Sprint planning effort: 1, 2, 3, or 5 (default: 3)
  --status STATUS           planned|ready|blocked|active|done|abandoned (default: planned)
  --planning-source SRC     local|roadmap (default: local)
  --source-ref TEXT         Optional source/revision marker for planning provenance
  --depends-on CSV          Comma-separated epic IDs (default: none)
  --prd-path PATH           PRD markdown path (default generated under active sprint tasks)
  --goal TEXT               Epic goal text (default: title)
  --prompt-context TEXT     Prompt context used by ralph-prime when PRD markdown is missing
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

ensure_file() {
  [ -f "$EPICS_FILE" ] || fail "Missing epics file: $EPICS_FILE"
  jq -e '.epics and (.epics | type == "array")' "$EPICS_FILE" >/dev/null 2>&1 || fail "Invalid epics JSON: $EPICS_FILE"
}

has_unsatisfied_dependencies() {
  local epic_id="$1"
  jq -e --arg id "$epic_id" '
    . as $root
    | ($root.epics[] | select(.id == $id) | (.dependsOn // [])) as $deps
    | any($deps[] as $dep; ($root.epics[] | select(.id == $dep) | .status // "missing") != "done")
  ' "$EPICS_FILE" >/dev/null 2>&1
}

find_next_epic_id() {
  local candidate_ids
  mapfile -t candidate_ids < <(jq -r '
    .epics
    | map(select((.status == "ready") or (.status == "planned")))
    | sort_by(.priority, .id)
    | .[].id
  ' "$EPICS_FILE")

  local epic_id
  for epic_id in "${candidate_ids[@]}"; do
    local deps
    deps="$(jq -r --arg id "$epic_id" '.epics[] | select(.id == $id) | (.dependsOn // [])[]?' "$EPICS_FILE")"
    local blocked=0
    local dep
    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      local dep_status
      dep_status="$(jq -r --arg dep "$dep" '.epics[] | select(.id == $dep) | .status // "missing"' "$EPICS_FILE")"
      if [ "$dep_status" != "done" ]; then
        blocked=1
        break
      fi
    done <<< "$deps"

    if [ "$blocked" -eq 0 ]; then
      printf '%s\n' "$epic_id"
      return 0
    fi
  done

  return 1
}

list_epics() {
  jq -r '
    .epics
    | sort_by(.priority, .id)
    | (["ID","P","EFF","SRC","STATUS","DEPENDS","TITLE","PRDS"] | @tsv),
      (.[] | [
        .id,
        (.priority | tostring),
        ((.effort // 0) | tostring),
        (.planningSource // "legacy"),
        .status,
        ((.dependsOn // []) | join(",")),
        .title,
        (((.prdPaths // []) | length) | tostring)
      ] | @tsv)
  ' "$EPICS_FILE" | column -ts $'\t'
}

show_epic() {
  local epic_id="$1"
  jq -e --arg id "$epic_id" '.epics[] | select(.id == $id)' "$EPICS_FILE" >/dev/null 2>&1 || fail "Epic not found: $epic_id"
  jq --arg id "$epic_id" '.epics[] | select(.id == $id)' "$EPICS_FILE"
}

set_status() {
  local epic_id="$1"
  local status="$2"
  local original_status="$status"
  if [ "$status" = "aborted" ]; then
    status="abandoned"
  fi

  case "$status" in
    planned|ready|blocked|active|done|abandoned)
      ;;
    *)
      fail "Invalid status '$original_status'. Use: planned|ready|blocked|active|done|abandoned"
      ;;
  esac

  jq -e --arg id "$epic_id" '.epics[] | select(.id == $id)' "$EPICS_FILE" >/dev/null 2>&1 || fail "Epic not found: $epic_id"

  local tmp_file
  tmp_file="$(mktemp)"
  jq --arg id "$epic_id" --arg status "$status" '
    .activeEpicId = (if $status == "active" then $id else .activeEpicId end)
    | .epics = (
      .epics
      | map(
          if .id == $id then
            .status = $status
            | if $status != "abandoned" then del(.abandonedAt, .abandonReason) else . end
          elif $status == "active" and .status == "active" then
            .status = "ready"
          else
            .
          end
        )
    )
    | if $status != "active" and .activeEpicId == $id then .activeEpicId = null else . end
  ' "$EPICS_FILE" > "$tmp_file"
  mv "$tmp_file" "$EPICS_FILE"

  echo "Updated $epic_id -> $status"
}

abandon_epic() {
  local epic_id="$1"
  local reason="${2:-}"
  jq -e --arg id "$epic_id" '.epics[] | select(.id == $id)' "$EPICS_FILE" >/dev/null 2>&1 || fail "Epic not found: $epic_id"

  local tmp_file
  tmp_file="$(mktemp)"
  jq --arg id "$epic_id" --arg reason "$reason" --arg ts "$(date -Iseconds)" '
    .activeEpicId = (if .activeEpicId == $id then null else .activeEpicId end)
    | .epics = (
      .epics
      | map(
          if .id == $id then
            .status = "abandoned"
            | .abandonedAt = $ts
            | if ($reason | length) > 0 then .abandonReason = $reason else . end
          else
            .
          end
        )
    )
  ' "$EPICS_FILE" > "$tmp_file"
  mv "$tmp_file" "$EPICS_FILE"

  if [ -n "$reason" ]; then
    echo "Updated $epic_id -> abandoned (reason recorded)"
  else
    echo "Updated $epic_id -> abandoned"
  fi
}

remove_epic() {
  local epic_id="$1"
  local status tmp_file
  jq -e --arg id "$epic_id" '.epics[] | select(.id == $id)' "$EPICS_FILE" >/dev/null 2>&1 || fail "Epic not found: $epic_id"

  status="$(jq -r --arg id "$epic_id" '.epics[] | select(.id == $id) | .status // empty' "$EPICS_FILE")"
  if [ "$status" != "abandoned" ]; then
    fail "Epic $epic_id is status '$status'. Only abandoned epics can be removed."
  fi

  tmp_file="$(mktemp)"
  jq --arg id "$epic_id" '
    .epics = [.epics[] | select(.id != $id)]
    | if .activeEpicId == $id then .activeEpicId = null else . end
  ' "$EPICS_FILE" > "$tmp_file"
  mv "$tmp_file" "$EPICS_FILE"

  echo "Removed epic: $epic_id"
}

normalize_statuses() {
  local tmp_file before_count after_count
  before_count="$(jq '[.epics[] | select(.status == "aborted")] | length' "$EPICS_FILE")"
  if [ "$before_count" -eq 0 ]; then
    echo "No legacy statuses to normalize."
    return 0
  fi

  tmp_file="$(mktemp)"
  jq '
    .epics = (
      .epics
      | map(
          if .status == "aborted" then
            .status = "abandoned"
          else
            .
          end
        )
    )
  ' "$EPICS_FILE" > "$tmp_file"
  mv "$tmp_file" "$EPICS_FILE"

  after_count="$(jq '[.epics[] | select(.status == "aborted")] | length' "$EPICS_FILE")"
  echo "Normalized legacy statuses: aborted -> abandoned (remaining aborted: $after_count)"
}

start_next() {
  local next_id
  next_id="$(find_next_epic_id)" || fail "No eligible next epic (all remaining epics are blocked or done)."
  set_status "$next_id" "active" >/dev/null
  local title
  title="$(jq -r --arg id "$next_id" '.epics[] | select(.id == $id) | .title' "$EPICS_FILE")"
  echo "Active epic: $next_id - $title"
}

show_next() {
  local next_id
  next_id="$(find_next_epic_id)" || fail "No eligible next epic (all remaining epics are blocked or done)."
  jq -r --arg id "$next_id" '
    .epics[]
    | select(.id == $id)
    | "Next epic: \(.id) (P\(.priority) E\(.effort // 0)) - \(.title)\nStatus: \(.status)\nDependsOn: \((.dependsOn // []) | join(", "))"
  ' "$EPICS_FILE"
}

show_next_id() {
  local next_id
  next_id="$(find_next_epic_id)" || fail "No eligible next epic (all remaining epics are blocked or done)."
  printf '%s\n' "$next_id"
}

next_epic_id() {
  local max_num
  max_num="$(jq -r '[.epics[]?.id | select(test("^EPIC-[0-9]{3}$")) | capture("^EPIC-(?<n>[0-9]{3})$").n | tonumber] | max // 0' "$EPICS_FILE")"
  printf 'EPIC-%03d\n' "$((max_num + 1))"
}

next_priority() {
  local max_priority
  max_priority="$(jq -r '[.epics[]?.priority | tonumber] | max // 0' "$EPICS_FILE")"
  printf '%s\n' "$((max_priority + 1))"
}

sanitize_slug() {
  local raw="$1"
  printf '%s' "$raw" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's|[^a-z0-9._-]+|-|g' \
    | sed -E 's|^-+||; s|-+$||'
}

default_prd_path_for_epic() {
  local epic_id="$1"
  local title="$2"
  local active_sprint
  active_sprint="$(get_active_sprint || true)"
  [ -n "$active_sprint" ] || fail "No active sprint. Use ./scripts/ralph/ralph-sprint.sh use <sprint-name> first."

  local epic_num slug
  epic_num="$(printf '%s\n' "$epic_id" | sed -E 's/^EPIC-([0-9]{3})$/\1/')"
  slug="$(sanitize_slug "$title")"
  [ -n "$slug" ] || slug="epic-${epic_num}"
  printf 'scripts/ralph/tasks/%s/prd-epic-%s-%s.md\n' "$active_sprint" "$epic_num" "$slug"
}

add_epic() {
  local epic_id=""
  local title=""
  local priority=""
  local effort="3"
  local status="planned"
  local planning_source="local"
  local source_ref=""
  local depends_csv=""
  local prd_path=""
  local goal=""
  local prompt_context=""
  shift

  while [ $# -gt 0 ]; do
    case "$1" in
      --id)
        epic_id="${2:-}"
        shift 2
        ;;
      --title)
        title="${2:-}"
        shift 2
        ;;
      --priority)
        priority="${2:-}"
        shift 2
        ;;
      --effort)
        effort="${2:-}"
        shift 2
        ;;
      --status)
        status="${2:-}"
        shift 2
        ;;
      --planning-source)
        planning_source="${2:-}"
        shift 2
        ;;
      --source-ref)
        source_ref="${2:-}"
        shift 2
        ;;
      --depends-on)
        depends_csv="${2:-}"
        shift 2
        ;;
      --prd-path)
        prd_path="${2:-}"
        shift 2
        ;;
      --goal)
        goal="${2:-}"
        shift 2
        ;;
      --prompt-context)
        prompt_context="${2:-}"
        shift 2
        ;;
      *)
        fail "Unknown add option '$1'"
        ;;
    esac
  done

  [ -n "$title" ] || fail "Usage: add --title <TEXT> [options]"

  case "$status" in
    planned|ready|blocked|active|done|abandoned) ;;
    *) fail "Invalid status '$status'. Use: planned|ready|blocked|active|done|abandoned" ;;
  esac
  case "$planning_source" in
    local|roadmap) ;;
    *) fail "Invalid planning source '$planning_source'. Use: local|roadmap" ;;
  esac

  if [ -z "$epic_id" ]; then
    epic_id="$(next_epic_id)"
  fi
  if [[ ! "$epic_id" =~ ^EPIC-[0-9]{3}$ ]]; then
    fail "Invalid epic ID '$epic_id'. Expected format: EPIC-XXX"
  fi

  jq -e --arg id "$epic_id" '.epics[] | select(.id == $id)' "$EPICS_FILE" >/dev/null 2>&1 \
    && fail "Epic ID already exists: $epic_id"

  if [ -z "$priority" ]; then
    priority="$(next_priority)"
  fi
  [[ "$priority" =~ ^[0-9]+$ ]] || fail "Priority must be an integer."
  [[ "$effort" =~ ^(1|2|3|5)$ ]] || fail "Effort must be one of: 1, 2, 3, 5"

  if [ -z "$goal" ]; then
    goal="$title"
  fi
  if [ -z "$prd_path" ]; then
    prd_path="$(default_prd_path_for_epic "$epic_id" "$title")"
  fi

  local -a depends_arr=()
  if [ -n "$depends_csv" ]; then
    IFS=',' read -r -a depends_arr <<< "$depends_csv"
  fi

  local dep
  for dep in "${depends_arr[@]}"; do
    dep="$(printf '%s' "$dep" | xargs)"
    [ -n "$dep" ] || continue
    [ "$dep" != "$epic_id" ] || fail "Epic $epic_id cannot depend on itself."
    jq -e --arg id "$dep" '.epics[] | select(.id == $id)' "$EPICS_FILE" >/dev/null 2>&1 \
      || fail "Dependency epic not found: $dep"
  done

  local depends_json
  depends_json="$(
    printf '%s\n' "${depends_arr[@]}" \
      | awk 'NF{gsub(/^[ \t]+|[ \t]+$/, "", $0); if(length) print}' \
      | jq -R . \
      | jq -s .
  )"

  local tmp_file
  tmp_file="$(mktemp)"
  jq --arg id "$epic_id" \
     --arg title "$title" \
     --argjson priority "$priority" \
     --argjson effort "$effort" \
     --arg status "$status" \
     --arg planningSource "$planning_source" \
     --arg sourceRef "$source_ref" \
     --arg prd "$prd_path" \
     --arg goal "$goal" \
     --arg prompt "$prompt_context" \
     --argjson depends "$depends_json" '
    .epics += [{
      id: $id,
      title: $title,
      priority: $priority,
      effort: $effort,
      status: $status,
      planningSource: $planningSource,
      sourceRef: (if ($sourceRef | length) > 0 then $sourceRef else null end),
      dependsOn: $depends,
      prdPaths: [$prd],
      goal: $goal,
      openQuestions: [],
      promptContext: $prompt
    }]
    | if $status == "active" then .activeEpicId = $id else . end
  ' "$EPICS_FILE" > "$tmp_file"
  mv "$tmp_file" "$EPICS_FILE"

  echo "Added epic: $epic_id - $title"
}

main() {
  require_cmd jq

  local cmd="${1:-}"
  case "$cmd" in
    -h|--help|help|"")
      usage
      return 0
      ;;
  esac

  resolve_epics_file
  ensure_file

  case "$cmd" in
    list)
      list_epics
      ;;
    add)
      shift
      add_epic add "$@"
      ;;
    next)
      show_next
      ;;
    next-id)
      show_next_id
      ;;
    start-next)
      start_next
      ;;
    set-status)
      [ $# -eq 3 ] || fail "Usage: set-status <ID> <STATUS>"
      set_status "$2" "$3"
      ;;
    normalize-statuses)
      normalize_statuses
      ;;
    abandon)
      [ $# -ge 2 ] || fail "Usage: abandon <ID> [REASON]"
      abandon_epic "$2" "${*:3}"
      ;;
    remove)
      [ $# -eq 2 ] || fail "Usage: remove <ID>"
      remove_epic "$2"
      ;;
    show)
      [ $# -eq 2 ] || fail "Usage: show <ID>"
      show_epic "$2"
      ;;
    *)
      fail "Unknown command '$cmd'"
      ;;
  esac
}

main "$@"
