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
const healthModule = path.join(repoRoot, 'scripts/ralph/commands/story/health.sh')
const authoringModule = path.join(repoRoot, 'scripts/ralph/commands/story/authoring.sh')
const preparationModule = path.join(repoRoot, 'scripts/ralph/commands/story/preparation.sh')
const preparationLibrary = path.join(repoRoot, 'scripts/ralph/lib/story-preparation.sh')
const generationModule = path.join(repoRoot, 'scripts/ralph/commands/story/generation.sh')
const specificationModule = path.join(repoRoot, 'scripts/ralph/commands/story/specification.sh')
const installScript = path.join(repoRoot, 'install.sh')

test('story lifecycle module is source-safe', () => {
  const result = spawnSync('bash', ['-c', 'set -u; source "$1"; declare -F cmd_next_id >/dev/null', 'bash', lifecycleModule], {
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, '')
  assert.equal(result.stderr, '')
})

test('story health module is source-safe', () => {
  const result = spawnSync('bash', ['-c', 'set -u; source "$1"; declare -F cmd_health >/dev/null; declare -F _health_story >/dev/null', 'bash', healthModule], {
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, '')
  assert.equal(result.stderr, '')
})

test('story authoring module is source-safe', () => {
  const result = spawnSync('bash', ['-c', 'set -u; source "$1"; declare -F cmd_add >/dev/null; declare -F cmd_import_story >/dev/null; declare -F cmd_import_prd >/dev/null', 'bash', authoringModule], {
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, '')
  assert.equal(result.stderr, '')
})

test('story preparation module is source-safe', () => {
  const result = spawnSync('bash', ['-c', 'set -u; source "$1"; declare -F cmd_specify_all >/dev/null; declare -F cmd_generate_all >/dev/null; declare -F cmd_prepare_all >/dev/null; declare -F cmd_prep_status >/dev/null', 'bash', preparationModule], {
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, '')
  assert.equal(result.stderr, '')
})

test('story preparation support library is source-safe', () => {
  const result = spawnSync('bash', ['-c', 'set -u; source "$1"; declare -F prep_record_stage >/dev/null; declare -F write_story_prep_bundle >/dev/null; declare -F compute_story_prep_fingerprint >/dev/null', 'bash', preparationLibrary], {
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, '')
  assert.equal(result.stderr, '')
})

test('story generation and specification modules are source-safe', () => {
  for (const [modulePath, functionName] of [
    [generationModule, 'cmd_generate'],
    [specificationModule, 'cmd_specify'],
  ]) {
    const result = spawnSync('bash', ['-c', 'set -u; source "$1"; declare -F "$2" >/dev/null', 'bash', modulePath, functionName], {
      encoding: 'utf8',
    })
    assert.equal(result.status, 0, result.stderr)
    assert.equal(result.stdout, '')
    assert.equal(result.stderr, '')
  }
})

test('story focus discovery preserves literal paths with the system awk', () => {
  const specifyLibrary = path.join(repoRoot, 'scripts/ralph/lib/specify.sh')
  const script = 'source "$1"; collect_story_focus_hints "$2" "Touch lib/example.ts and __tests__/example.test.ts."'
  const result = spawnSync('bash', ['-c', script, 'bash', specifyLibrary, repoRoot], { encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stderr, '')
  assert.match(result.stdout, /- `lib\/example\.ts`/)
  assert.match(result.stdout, /- `__tests__\/example\.test\.ts`/)
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

test('ralph-story lazily loads health commands and preserves healthy output', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-story-health-'))
  const storyPath = path.join(root, 'S-001', 'story.json')
  const storiesFile = path.join(root, 'stories.json')
  fs.mkdirSync(path.dirname(storyPath), { recursive: true })
  fs.writeFileSync(storyPath, JSON.stringify({
    storyId: 'S-001',
    tasks: [{ id: 'T-001', title: 'Check module', status: 'pending', context: 'Validate extraction', depends_on: [], checks: ['true'] }],
  }))
  fs.writeFileSync(storiesFile, JSON.stringify({
    sprint: 'sprint-1',
    activeStoryId: null,
    stories: [{ id: 'S-001', priority: 1, effort: 1, status: 'ready', title: 'Healthy', story_path: storyPath }],
  }))

  const result = spawnSync(storyScript, ['health', 'S-001'], {
    cwd: repoRoot,
    env: { ...process.env, RALPH_STORIES_FILE: storiesFile },
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /\[S-001\] ready/)
  assert.match(result.stdout, /  OK/)
})

test('ralph-story lazily loads authoring commands and imports a valid container', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-story-import-'))
  const storyPath = path.join(root, 'S-001', 'story.json')
  const sourcePath = path.join(root, 'import.json')
  const storiesFile = path.join(root, 'stories.json')
  fs.writeFileSync(sourcePath, JSON.stringify({
    storyId: 'S-001', sprint: 'sprint-1', status: 'ready', passes: false,
    tasks: [{ id: 'T-001', title: 'Imported task', status: 'pending', context: 'Imported', depends_on: [], checks: ['true'] }],
  }))
  fs.writeFileSync(storiesFile, JSON.stringify({
    sprint: 'sprint-1', activeStoryId: null,
    stories: [{ id: 'S-001', priority: 1, effort: 1, status: 'planned', title: 'Import', story_path: storyPath }],
  }))

  const result = spawnSync(storyScript, ['import-story', 'S-001', sourcePath], {
    cwd: repoRoot,
    env: { ...process.env, RALPH_STORIES_FILE: storiesFile },
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /Imported story container for S-001/)
  assert.equal(JSON.parse(fs.readFileSync(storiesFile, 'utf8')).stories[0].status, 'ready')
  assert.equal(fs.existsSync(storyPath), true)
})

test('installer includes the lifecycle command module', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-module-install-'))
  const result = spawnSync(installScript, ['--project', root, '--skip-git-check', '--no-setup-harnesses', '--no-install-speckit', '--verify-setup', 'skip'], {
    cwd: repoRoot,
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/commands/story/lifecycle.sh')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/commands/story/health.sh')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/commands/story/authoring.sh')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/commands/story/preparation.sh')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/lib/story-preparation.sh')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/lib/sprint-layout.sh')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/commands/story/generation.sh')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/commands/story/specification.sh')), true)
})
