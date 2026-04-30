'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { execFileSync, spawnSync } = require('node:child_process')

const REPO_ROOT = path.resolve(__dirname, '..')

function run(cmd, args, { cwd, env } = {}) {
  return execFileSync(cmd, args, {
    cwd,
    env: { ...process.env, ...env },
    encoding: 'utf8',
    stdio: 'pipe',
  })
}

function tryRun(cmd, args, { cwd, env } = {}) {
  return spawnSync(cmd, args, {
    cwd,
    env: { ...process.env, ...env },
    encoding: 'utf8',
    stdio: 'pipe',
  })
}

function writeFile(targetPath, contents) {
  fs.mkdirSync(path.dirname(targetPath), { recursive: true })
  fs.writeFileSync(targetPath, contents)
}

function chmodScripts(rootDir) {
  const stack = [rootDir]
  while (stack.length > 0) {
    const current = stack.pop()
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const fullPath = path.join(current, entry.name)
      if (entry.isDirectory()) { stack.push(fullPath); continue }
      if (entry.name.endsWith('.sh')) fs.chmodSync(fullPath, 0o755)
    }
  }
}

function initTempRepo({ branch = 'master' } = {}) {
  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-test-'))
  const frameworkRoot = path.join(repoDir, 'scripts', 'ralph')
  fs.mkdirSync(path.dirname(frameworkRoot), { recursive: true })
  fs.cpSync(REPO_ROOT, frameworkRoot, {
    recursive: true,
    filter: (src) =>
      !src.includes(`${path.sep}.git${path.sep}`) &&
      !src.endsWith(`${path.sep}.git`),
  })
  chmodScripts(frameworkRoot)

  run('git', ['init', '-b', branch], { cwd: repoDir })
  run('git', ['config', 'user.name', 'Ralph Test'], { cwd: repoDir })
  run('git', ['config', 'user.email', 'ralph-test@example.com'], { cwd: repoDir })
  run('git', ['add', '.'], { cwd: repoDir })
  run('git', ['commit', '-m', 'init'], { cwd: repoDir })
  return repoDir
}

function storiesJson(sprint, { status = 'planned', stories = [], activeStoryId = null } = {}) {
  return JSON.stringify(
    {
      version: 1,
      project: 'tmp-ralph-test',
      sprint,
      status,
      capacityTarget: 8,
      capacityCeiling: 10,
      activeStoryId,
      stories,
    },
    null,
    2
  )
}

function storyRecord(id, { title = 'Test story', status = 'ready', storyPath = null } = {}) {
  const entry = { id, title, priority: 1, effort: 1, status }
  if (storyPath) entry.story_path = storyPath
  return entry
}

// ---------------------------------------------------------------------------
// ralph-sprint next — sprint selection
// ---------------------------------------------------------------------------

test('ralph-sprint next returns the first ready sprint in sorted order', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'closed',
      stories: [storyRecord('S-001', { status: 'done' })],
    })
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-2/stories.json'),
    storiesJson('sprint-2', {
      status: 'ready',
      stories: [storyRecord('S-001', { status: 'ready' })],
    })
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-10/stories.json'),
    storiesJson('sprint-10', {
      status: 'ready',
      stories: [storyRecord('S-001', { status: 'ready' })],
    })
  )

  const output = run('./scripts/ralph/ralph-sprint.sh', ['next'], { cwd: repoDir })
  assert.equal(output.trim(), 'sprint-2')
})

test('ralph-sprint next skips planned and closed sprints, returning only ready ones', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'planned',
      stories: [storyRecord('S-001', { status: 'planned' })],
    })
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-2/stories.json'),
    storiesJson('sprint-2', {
      status: 'ready',
      stories: [storyRecord('S-001', { status: 'ready' })],
    })
  )

  const output = run('./scripts/ralph/ralph-sprint.sh', ['next'], { cwd: repoDir })
  assert.equal(output.trim(), 'sprint-2')
})

test('ralph-sprint next skips historic blocked-only sprints before the roadmap baseline', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/roadmap.json'),
    JSON.stringify({ sprints: [{ name: 'sprint-3' }, { name: 'sprint-4' }] }, null, 2)
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'planned',
      stories: [storyRecord('S-001', { status: 'blocked' })],
    })
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-3/stories.json'),
    storiesJson('sprint-3', {
      status: 'ready',
      stories: [storyRecord('S-001', { status: 'ready' })],
    })
  )

  const output = run('./scripts/ralph/ralph-sprint.sh', ['next'], { cwd: repoDir })
  assert.equal(output.trim(), 'sprint-3')
})

// ---------------------------------------------------------------------------
// ralph-sprint next --activate — activation via find_next_sprint
// ---------------------------------------------------------------------------

test('ralph-sprint next --activate activates the next ready sprint and checks out its branch', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'closed',
      stories: [storyRecord('S-001', { status: 'done' })],
    })
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-2/stories.json'),
    storiesJson('sprint-2', {
      status: 'ready',
      stories: [storyRecord('S-001', { status: 'ready' })],
    })
  )

  const output = run('./scripts/ralph/ralph-sprint.sh', ['next', '--activate'], { cwd: repoDir })
  assert.match(output, /^sprint-2$/m)
  assert.match(output, /Active sprint set to: sprint-2/)
  assert.match(output, /Checked out sprint branch: ralph\/sprint\/sprint-2/)
  assert.equal(
    fs.readFileSync(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'utf8'),
    'sprint-2\n'
  )
  assert.equal(run('git', ['branch', '--show-current'], { cwd: repoDir }).trim(), 'ralph/sprint/sprint-2')
})

// ---------------------------------------------------------------------------
// ralph-sprint mark-ready — sprint readiness gate
// ---------------------------------------------------------------------------

test('ralph-sprint mark-ready fails when stories are not ready', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-user-auth/stories.json'),
    storiesJson('sprint-user-auth', {
      status: 'planned',
      stories: [
        storyRecord('S-001', { status: 'ready' }),
        storyRecord('S-002', { status: 'planned' }),
      ],
    })
  )

  const result = tryRun('./scripts/ralph/ralph-sprint.sh', ['mark-ready', 'sprint-user-auth'], {
    cwd: repoDir,
  })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /S-002/)
})

test('ralph-sprint mark-ready succeeds when all active stories are ready', () => {
  const repoDir = initTempRepo()

  const sprintFile = path.join(repoDir, 'scripts/ralph/sprints/sprint-user-auth/stories.json')
  writeFile(
    sprintFile,
    storiesJson('sprint-user-auth', {
      status: 'planned',
      stories: [
        storyRecord('S-001', { status: 'ready' }),
        storyRecord('S-002', { status: 'done' }),
        storyRecord('S-003', { status: 'abandoned' }),
      ],
    })
  )

  const output = run('./scripts/ralph/ralph-sprint.sh', ['mark-ready', 'sprint-user-auth'], {
    cwd: repoDir,
  })
  assert.match(output, /marked ready/)
  const data = JSON.parse(fs.readFileSync(sprintFile, 'utf8'))
  assert.equal(data.status, 'ready')
})

test('ralph-sprint mark-ready rejects already-active or closed sprints', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-user-auth/stories.json'),
    storiesJson('sprint-user-auth', {
      status: 'active',
      stories: [storyRecord('S-001', { status: 'ready' })],
    })
  )

  const result = tryRun('./scripts/ralph/ralph-sprint.sh', ['mark-ready', 'sprint-user-auth'], {
    cwd: repoDir,
  })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /already active/)
})

// ---------------------------------------------------------------------------
// ralph-sprint use — activation gate
// ---------------------------------------------------------------------------

test('ralph-sprint use fails when sprint status is not ready', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-user-auth/stories.json'),
    storiesJson('sprint-user-auth', {
      status: 'planned',
      stories: [storyRecord('S-001', { status: 'planned' })],
    })
  )

  const result = tryRun('./scripts/ralph/ralph-sprint.sh', ['use', 'sprint-user-auth'], {
    cwd: repoDir,
  })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /not ready/)
})

test('ralph-sprint use fails when previous sprint is not closed', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'active',
      stories: [storyRecord('S-001', { status: 'done' })],
    })
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-2/stories.json'),
    storiesJson('sprint-2', {
      status: 'ready',
      stories: [storyRecord('S-001', { status: 'ready' })],
    })
  )

  const result = tryRun('./scripts/ralph/ralph-sprint.sh', ['use', 'sprint-2'], {
    cwd: repoDir,
  })
  assert.equal(result.status, 1)
  assert.match(result.stderr, /not closed/)
})

test('ralph-sprint use succeeds when sprint is ready and previous sprint is closed', () => {
  const repoDir = initTempRepo()

  const sprint2File = path.join(repoDir, 'scripts/ralph/sprints/sprint-2/stories.json')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/stories.json'),
    storiesJson('sprint-1', {
      status: 'closed',
      stories: [storyRecord('S-001', { status: 'done' })],
    })
  )
  writeFile(
    sprint2File,
    storiesJson('sprint-2', {
      status: 'ready',
      stories: [storyRecord('S-001', { status: 'ready' })],
    })
  )

  const output = run('./scripts/ralph/ralph-sprint.sh', ['use', 'sprint-2'], { cwd: repoDir })
  assert.match(output, /Active sprint set to: sprint-2/)
  assert.equal(
    fs.readFileSync(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'utf8'),
    'sprint-2\n'
  )
  assert.equal(run('git', ['branch', '--show-current'], { cwd: repoDir }).trim(), 'ralph/sprint/sprint-2')
  const data = JSON.parse(fs.readFileSync(sprint2File, 'utf8'))
  assert.equal(data.status, 'active')
})

test('ralph-sprint use succeeds for the first sprint with no previous sprint', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-user-auth/stories.json'),
    storiesJson('sprint-user-auth', {
      status: 'ready',
      stories: [storyRecord('S-001', { status: 'ready' })],
    })
  )

  const output = run('./scripts/ralph/ralph-sprint.sh', ['use', 'sprint-user-auth'], {
    cwd: repoDir,
  })
  assert.match(output, /Active sprint set to: sprint-user-auth/)
  assert.equal(run('git', ['branch', '--show-current'], { cwd: repoDir }).trim(), 'ralph/sprint/sprint-user-auth')
})
