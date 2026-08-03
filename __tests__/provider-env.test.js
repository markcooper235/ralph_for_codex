'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const providerLibrary = path.resolve(__dirname, '../scripts/ralph/lib/provider-env.sh')
const harnessLibrary = path.resolve(__dirname, '../scripts/ralph/lib/harness-exec.sh')

function evaluate(env, expression) {
  return spawnSync('bash', ['-c', `source "$1"; ralph_normalize_provider_env; ${expression}`, 'bash', providerLibrary], {
    env: { PATH: process.env.PATH, HOME: process.env.HOME, ...env },
    encoding: 'utf8',
  })
}

test('OpenRouter credentials are mapped to both Codex and Pi', () => {
  const result = evaluate(
    { OPENROUTER_BASE_URL: 'https://openrouter.ai/api/v1', OPENROUTER_API_KEY: 'test-openrouter-key' },
    'test "$OPENAI_API_KEY" = "$OPENROUTER_API_KEY"; test "$PI_API_KEY" = "$OPENROUTER_API_KEY"; ralph_provider_route_for_harness codex; ralph_provider_route_for_harness piagent'
  )
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, 'openrouter\nopenrouter\n')
})

test('native OpenAI credentials are mapped to both Codex and Pi', () => {
  const result = evaluate(
    { OPENAI_API_BASE_NATIVE: 'https://api.openai.com/v1', OPENAI_API_KEY_NATIVE: 'test-native-key' },
    'test "$OPENAI_API_KEY" = "$OPENAI_API_KEY_NATIVE"; test "$PI_API_KEY" = "$OPENAI_API_KEY_NATIVE"; ralph_provider_route_for_harness codex; ralph_provider_route_for_harness piagent'
  )
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, 'openai-compatible\nopenai-compatible\n')
})

test('Codex API key alias is supported without overriding explicit Pi credentials', () => {
  const result = evaluate(
    { CODEX_API_KEY: 'test-codex-key', PI_API_KEY: 'test-pi-key', PI_BASE_URL: 'https://example.invalid/v1' },
    'test "$OPENAI_API_KEY" = "$CODEX_API_KEY"; test "$PI_API_KEY" = "test-pi-key"'
  )
  assert.equal(result.status, 0, result.stderr)
})

test('OpenRouter model identifiers are provider-qualified for both harnesses', () => {
  const result = spawnSync('bash', ['-c', 'source "$1"; printf "%s\\n" "$(_resolve_codex_model gpt-5.4-mini)" "$(_resolve_piagent_model gpt-5.4-mini)"', 'bash', harnessLibrary], {
    env: { PATH: process.env.PATH, HOME: process.env.HOME, OPENAI_BASE_URL: 'https://openrouter.ai/api/v1', PI_BASE_URL: 'https://openrouter.ai/api/v1' },
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, 'openai/gpt-5.4-mini\nopenrouter/openai/gpt-5.4-mini\n')
})
