#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || cd "$SCRIPT_DIR/../.." && pwd)"
PLAYWRIGHT_CLI_DIR="$WORKSPACE_ROOT/.playwright-cli"

: > "$SCRIPT_DIR/prd.json"

rm -f \
  "$SCRIPT_DIR/progress.txt" \
  "$SCRIPT_DIR/.last-branch" \
  "$SCRIPT_DIR/.codex-last-message.txt" \
  "$SCRIPT_DIR/.codex-last-message-iter-"*.txt
rm -rf "$PLAYWRIGHT_CLI_DIR"

echo "Ralph cleanup complete (no archive created, prd.json reset, .playwright-cli cleared)."
