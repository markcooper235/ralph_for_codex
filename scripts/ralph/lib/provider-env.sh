#!/bin/bash
# Shared .ralph-env loading and OpenAI-compatible provider normalization.
# Sourcing this file performs no work and never prints credential values.

ralph_load_env_file() {
  local env_file="$1"
  [ -f "$env_file" ] || return 1
  set -a
  # shellcheck source=/dev/null
  . "$env_file"
  set +a
}

ralph_normalize_provider_env() {
  local shared_base="${OPENROUTER_BASE_URL:-${OPENAI_BASE_URL:-${PI_BASE_URL:-}}}"
  local shared_key="${OPENROUTER_API_KEY:-${OPENAI_API_KEY:-${CODEX_API_KEY:-${PI_API_KEY:-}}}}"

  if [ -z "$shared_key" ] && [ -n "${OPENAI_API_KEY_NATIVE:-${CODEX_API_KEY_NATIVE:-}}" ]; then
    shared_key="${OPENAI_API_KEY_NATIVE:-$CODEX_API_KEY_NATIVE}"
    shared_base="${OPENAI_API_BASE_NATIVE:-https://api.openai.com/v1}"
  fi

  if [ -n "$shared_base" ]; then
    : "${OPENAI_BASE_URL:=$shared_base}"
    : "${PI_BASE_URL:=$shared_base}"
  fi
  if [ -n "$shared_key" ]; then
    : "${OPENAI_API_KEY:=$shared_key}"
    : "${PI_API_KEY:=$shared_key}"
  fi

  export OPENAI_BASE_URL OPENAI_API_KEY PI_BASE_URL PI_API_KEY
}

ralph_load_provider_env() {
  local script_dir="$1"
  if ! ralph_load_env_file "$script_dir/.ralph-env"; then
    ralph_load_env_file "$HOME/.ralph-env" || true
  fi
  ralph_normalize_provider_env
}

ralph_provider_route_for_harness() {
  local harness="$1"
  case "$harness" in
    codex)
      [ -n "${OPENAI_API_KEY:-}" ] || return 1
      ;;
    piagent)
      [ -n "${PI_API_KEY:-}" ] || return 1
      ;;
    *) return 1 ;;
  esac

  case "${OPENROUTER_BASE_URL:-${OPENAI_BASE_URL:-${PI_BASE_URL:-}}}" in
    *openrouter.ai*) printf 'openrouter\n' ;;
    *) printf 'openai-compatible\n' ;;
  esac
}
