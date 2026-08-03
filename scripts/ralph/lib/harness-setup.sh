#!/bin/bash
# lib/harness-setup.sh — Install and validate Ralph's external harnesses.
#
# This library deliberately does not load .ralph-env. Harness binaries and
# extensions are machine-level setup; provider credentials remain operator
# managed and are never copied or staged by install.sh.

RALPH_PI_SUBAGENTS_PACKAGE="${RALPH_PI_SUBAGENTS_PACKAGE:-npm:pi-subagents@0.27.0}"

_ralph_harness_setup_require_npm() {
  command -v npm >/dev/null 2>&1 || {
    echo "ERROR: npm is required to install missing Ralph harnesses." >&2
    return 1
  }
}

_ralph_harness_setup_install_global() {
  local package_name="$1"
  shift
  echo "Installing harness package: $package_name"
  npm install -g "$@" "$package_name"
}

ralph_harness_setup_codex() {
  if command -v codex >/dev/null 2>&1; then
    echo "Harness ready: codex ($(command -v codex))"
    return 0
  fi

  _ralph_harness_setup_require_npm || return 1
  _ralph_harness_setup_install_global "@openai/codex" || return 1
  command -v codex >/dev/null 2>&1 || {
    echo "ERROR: Codex installation completed but codex is not on PATH." >&2
    return 1
  }
  echo "Harness ready: codex ($(command -v codex))"
}

ralph_harness_setup_piagent() {
  if ! command -v pi >/dev/null 2>&1; then
    _ralph_harness_setup_require_npm || return 1
    _ralph_harness_setup_install_global "@earendil-works/pi-coding-agent" --ignore-scripts || return 1
  fi

  command -v pi >/dev/null 2>&1 || {
    echo "ERROR: Pi installation completed but pi is not on PATH." >&2
    return 1
  }
  echo "Harness ready: pi ($(command -v pi))"

  local pi_agent_dir="${PI_CODING_AGENT_DIR:-${HOME:-$PWD}/.pi/agent}"
  local package_json="$pi_agent_dir/npm/node_modules/pi-subagents/package.json"
  local installed_version=""
  local expected_version="${RALPH_PI_SUBAGENTS_PACKAGE##*@}"
  if [ -f "$package_json" ] && command -v jq >/dev/null 2>&1; then
    installed_version="$(jq -r '.version // empty' "$package_json" 2>/dev/null || true)"
  fi

  if pi list 2>/dev/null | grep -Eq '^pi-subagents([[:space:]]|$)' && [ "$installed_version" = "$expected_version" ]; then
    echo "Pi extension ready: pi-subagents@$installed_version"
    return 0
  fi

  echo "Installing compatible Pi extension: $RALPH_PI_SUBAGENTS_PACKAGE"
  PI_CODING_AGENT_DIR="$pi_agent_dir" pi install "$RALPH_PI_SUBAGENTS_PACKAGE"
  echo "Pi extension ready: pi-subagents@$expected_version"
}

ralph_harness_setup_all() {
  ralph_harness_setup_codex
  ralph_harness_setup_piagent
}
