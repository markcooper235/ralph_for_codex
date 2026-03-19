#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_FILE="${RALPH_COMPACT_RECOMMEND_LOG:-$REPO_ROOT/scripts/ralph/.metrics/compact-recommendations.jsonl}"

usage() {
  cat <<'USAGE'
Usage: scripts/smoke/compact-recommend-review.sh <command> [args]

Commands:
  stats                    Show recommendation review stats
  pending                  List pending recommended cases
  mark <id> <good|bad|unknown>
                           Review a recommendation outcome
USAGE
}

require_log() {
  [ -f "$LOG_FILE" ] || {
    echo "No recommendation log found at: $LOG_FILE" >&2
    exit 1
  }
}

cmd_stats() {
  require_log
  jq -s '
    def reviewed: map(select(.reviewLabel == "good" or .reviewLabel == "bad"));
    def pending: map(select(.reviewLabel == "pending"));
    def recommended: map(select(.recommendedCompact == true));
    {
      totalObservations: length,
      recommendedCount: (recommended | length),
      compactSelectedCount: (map(select(.compactSelected == true)) | length),
      pendingReviewCount: (pending | length),
      reviewedGoodCount: (reviewed | map(select(.reviewLabel == "good")) | length),
      reviewedBadCount: (reviewed | map(select(.reviewLabel == "bad")) | length),
      falsePositiveRate: (
        if (reviewed | length) == 0 then null
        else ((reviewed | map(select(.reviewLabel == "bad")) | length) / (reviewed | length))
        end
      )
    }
  ' "$LOG_FILE"
}

cmd_pending() {
  require_log
  jq -r '
    select(.reviewLabel == "pending")
    | [
        .id,
        "recommended=\(.recommendedCompact)",
        "compactSelected=\(.compactSelected)",
        "reason=\(.recommendationReason)",
        "paths=\(.distinctPathCount)",
        "stories=\(.generatedStoryCount)",
        .timestamp
      ] | @tsv
  ' "$LOG_FILE"
}

cmd_mark() {
  local id="$1"
  local label="$2"
  local tmp_file

  require_log
  case "$label" in
    good|bad|unknown) ;;
    *)
      echo "Invalid label: $label" >&2
      exit 1
      ;;
  esac

  tmp_file="$(mktemp)"
  jq --arg id "$id" --arg label "$label" --arg reviewed_at "$(date -Iseconds)" '
    if .id == $id then
      .reviewLabel = $label | .reviewedAt = $reviewed_at
    else
      .
    end
  ' "$LOG_FILE" > "$tmp_file"

  if ! jq -e --arg id "$id" 'select(.id == $id)' "$tmp_file" >/dev/null 2>&1; then
    rm -f "$tmp_file"
    echo "No observation found for id: $id" >&2
    exit 1
  fi

  mv "$tmp_file" "$LOG_FILE"
  echo "Updated $id -> $label"
}

case "${1:-}" in
  stats)
    cmd_stats
    ;;
  pending)
    cmd_pending
    ;;
  mark)
    [ $# -eq 3 ] || {
      usage
      exit 1
    }
    cmd_mark "$2" "$3"
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    echo "Unknown command: $1" >&2
    usage
    exit 1
    ;;
esac
