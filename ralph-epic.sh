#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EPICS_FILE="${RALPH_EPICS_FILE:-$SCRIPT_DIR/epics.json}"

usage() {
  cat <<'EOF'
Usage: ./scripts/ralph/ralph-epic.sh <command> [args]

Commands:
  list                      List all epics ordered by priority
  next                      Show the next eligible epic
  start-next                Mark next eligible epic as active
  set-status <ID> <STATUS>  Set epic status (planned|ready|blocked|active|done|abandoned)
  abandon <ID> [REASON]     Mark epic as abandoned (kept for historical reference)
  remove <ID>               Remove an abandoned epic from epics.json
  show <ID>                 Show full epic JSON

Eligibility for "next":
  - status is ready or planned
  - all dependencies are status=done
  - lowest priority wins, then ID
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
    | (["ID","P","STATUS","DEPENDS","TITLE","PRDS"] | @tsv),
      (.[] | [
        .id,
        (.priority | tostring),
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
    | "Next epic: \(.id) (P\(.priority)) - \(.title)\nStatus: \(.status)\nDependsOn: \((.dependsOn // []) | join(", "))"
  ' "$EPICS_FILE"
}

main() {
  require_cmd jq
  ensure_file

  local cmd="${1:-}"
  case "$cmd" in
    list)
      list_epics
      ;;
    next)
      show_next
      ;;
    start-next)
      start_next
      ;;
    set-status)
      [ $# -eq 3 ] || fail "Usage: set-status <ID> <STATUS>"
      set_status "$2" "$3"
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
    -h|--help|help|"")
      usage
      ;;
    *)
      fail "Unknown command '$cmd'"
      ;;
  esac
}

main "$@"
