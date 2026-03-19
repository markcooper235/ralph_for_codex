#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$SCRIPT_DIR/.benchmarks"
BENCH_FILE="$BENCH_DIR/e2e-history.tsv"

usage() {
  cat <<'USAGE'
Usage: scripts/smoke/bench-history.sh [latest|tail [N]]

Commands:
  latest     Show the most recent benchmark row (default)
  tail [N]   Show the last N rows (default: 10)
USAGE
}

cmd="${1:-latest}"

if [ ! -f "$BENCH_FILE" ]; then
  echo "No smoke benchmark history found at $BENCH_FILE" >&2
  exit 1
fi

case "$cmd" in
  latest)
    tail -n 1 "$BENCH_FILE"
    ;;
  tail)
    count="${2:-10}"
    tail -n "$count" "$BENCH_FILE"
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac
