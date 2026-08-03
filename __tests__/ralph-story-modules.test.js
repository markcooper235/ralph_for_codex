'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const repoRoot = path.resolve(__dirname, '..')
const storyScript = path.join(repoRoot, 'scripts/ralph/ralph-story.sh')
const lifecycleModule = path.join(repoRoot, 'scripts/ralph/commands/story/lifecycle.sh')
const installScript = path.join(repoRoot, 'install.sh')

test('story lifecycle module is source-safe', () => {
  const result = spawnSync('bash', ['-c', 'set -u; source "$1"; declare -F cmd_next_id >/dev/null', 'bash', lifecycleModule], {
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, '')
  assert.equal(result.stderr, '')
})

test('ralph-story lazily loads lifecycle commands and preserves next-id behavior', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-story-module-'))
  const storiesFile = path.join(root, 'stories.json')
  fs.writeFileSync(storiesFile, JSON.stringify({
    sprint: 'sprint-1',
    activeStoryId: null,
    stories: [
      { id: 'S-001', priority: 1, effort: 1, status: 'ready', title: 'Blocked', depends_on: ['S-003'] },
      { id: 'S-002', priority: 2, effort: 1, status: 'ready', title: 'Eligible', depends_on: [] },
      { id: 'S-003', priority: 3, effort: 1, status: 'planned', title: 'Dependency', depends_on: [] },
    ],
  }))

  const result = spawnSync(storyScript, ['next-id'], {
    cwd: repoRoot,
    env: { ...process.env, RALPH_STORIES_FILE: storiesFile },
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout.trim(), 'S-002')
})

test('ralph-story help does not load the lifecycle module', () => {
  const source = fs.readFileSync(storyScript, 'utf8')
  assert.match(source, /list\|show\|next\|next-id\|use\|start-next\|tasks\|set-status\|abandon/)
  const result = spawnSync(storyScript, ['--help'], { cwd: repoRoot, encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /^Usage: \.\/ralph-story\.sh <command>/)
})

test('installer includes the lifecycle command module', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-module-install-'))
  const result = spawnSync(installScript, ['--project', root, '--skip-git-check', '--no-install-speckit', '--verify-setup', 'skip'], {
    cwd: repoRoot,
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/commands/story/lifecycle.sh')), true)
})
