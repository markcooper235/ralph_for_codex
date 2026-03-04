#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || cd "$SCRIPT_DIR/../.." && pwd)"
PLAYWRIGHT_CLI_DIR="$WORKSPACE_ROOT/.playwright-cli"
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --force|-f|--yes)
      FORCE=1
      ;;
    -h|--help)
      echo "Usage: ./ralph-cleanup.sh [--force]"
      echo "  --force    Skip confirmation prompt"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Use --help for usage." >&2
      exit 1
      ;;
  esac
done

if [ "$FORCE" -ne 1 ]; then
  if [ ! -t 0 ]; then
    echo "Refusing non-interactive destructive cleanup without --force." >&2
    exit 1
  fi
  read -r -p "Cleanup will reset prd.json and delete local Ralph artifacts. Continue? [y/N]: " reply
  case "${reply,,}" in
    y|yes)
      ;;
    *)
      echo "Canceled."
      exit 1
      ;;
  esac
fi

: > "$SCRIPT_DIR/prd.json"

rm -f \
  "$SCRIPT_DIR/progress.txt" \
  "$SCRIPT_DIR/.last-branch" \
  "$SCRIPT_DIR/.codex-last-message.txt" \
  "$SCRIPT_DIR/.codex-last-message-iter-"*.txt
rm -rf "$PLAYWRIGHT_CLI_DIR"

echo "Ralph cleanup complete (no archive created, prd.json reset, .playwright-cli cleared)."
