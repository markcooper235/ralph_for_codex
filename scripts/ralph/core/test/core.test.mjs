import assert from 'node:assert/strict'
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { selectNextStory } from '../domain/sprint.mjs'
import { taskDependenciesMet, verificationDecision, storyIsComplete } from '../domain/task.mjs'
import { validateBacklog, validateStory } from '../domain/validation.mjs'
import { readBacklog, writeBacklogAtomic } from '../repositories/backlog-repository.mjs'
import { activateStory } from '../application/activate-story.mjs'
import { listStories, getStoryTasks } from '../application/story-view.mjs'
import { buildExecutionContext } from '../application/execution-context.mjs'
import { buildExecutionFiles } from '../application/execution-files.mjs'
import { buildExecutionChecks } from '../application/execution-plan.mjs'
import { buildProjectCommandMap } from '../application/project-commands.mjs'
import { runHarnessProcess } from '../adapters/process-runner.mjs'
import { runCheck } from '../application/check-runner.mjs'
import { fingerprintCheck } from '../application/check-fingerprint.mjs'
import { getBranchParent } from '../application/branch-parent.mjs'
import { mergeStoryBranch } from '../application/merge-story-branch.mjs'
import { ensureSprintBranch } from '../application/ensure-sprint-branch.mjs'
import { buildStatusReport, renderStatusReport } from '../application/status-report.mjs'
import { getActiveSprint, getSprintStatus, setActiveSprint, setSprintStatus } from '../application/sprint-state.mjs'
import { validateStoryContainer } from '../application/story-container.mjs'
import { inferChecksFromText } from '../application/check-inference.mjs'
import { computePrepFingerprint } from '../application/prep-fingerprint.mjs'
import { analyzeStoryHealth } from '../application/story-health.mjs'
import { finalizePrepSummary, recordPrepStage, rollupPrepStages } from '../application/prep-journal.mjs'
import { writeFallowReport } from '../application/fallow-report.mjs'
import { pruneRuntimeRuns } from '../application/runtime-cleanup.mjs'
import { pruneArchiveRetention } from '../application/archive-retention.mjs'
import { runTaskChecks } from '../application/task-check-runner.mjs'
import { collectStoryScope } from '../application/verification-scope.mjs'

async function withTempDir(callback) {
  const directory = await mkdtemp(join(tmpdir(), 'ralph-core-'))
  try {
    return await callback(directory)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
}

test('selectNextStory respects status, priority, id, and completed dependencies', () => {
  const stories = [
    { id: 'S-002', status: 'planned', priority: 1, depends_on: ['S-001'] },
    { id: 'S-003', status: 'ready', priority: 2, depends_on: [] },
    { id: 'S-001', status: 'done', priority: 3, depends_on: [] },
  ]
  assert.equal(selectNextStory(stories).id, 'S-002')
})

test('domain validators reject malformed containers', () => {
  assert.throws(() => validateBacklog({ stories: [{ id: '' }] }), /every story/)
  assert.throws(() => validateStory({ tasks: [{ id: '' }] }), /every task/)
})

test('task verification is blocked until dependencies pass and completion is strict', () => {
  const story = {
    status: 'active',
    passes: false,
    tasks: [
      { id: 'T-01', passes: false },
      { id: 'T-02', depends_on: ['T-01'], passes: false },
    ],
  }
  assert.equal(taskDependenciesMet(story, 'T-02'), false)
  assert.deepEqual(verificationDecision(story, 'T-02'), { state: 'blocked', failureSeen: true })
  assert.equal(storyIsComplete(story), false)
})

test('backlog and story writes are atomic and expose lifecycle views', async () => {
  await withTempDir(async (directory) => {
    const backlogPath = join(directory, 'stories.json')
    const storyPath = join(directory, 'stories', 'S-001', 'story.json')
    const backlog = {
      sprint: 'sprint-test',
      activeStoryId: null,
      stories: [{ id: 'S-001', title: 'One', status: 'planned', priority: 1, effort: 1, story_path: storyPath }],
    }
    await writeBacklogAtomic(backlogPath, backlog)
    await mkdir(join(directory, 'stories', 'S-001'), { recursive: true })
    await writeFile(storyPath, JSON.stringify({ storyId: 'S-001', tasks: [{ id: 'T-01', status: 'pending', passes: false }] }))
    await activateStory(backlogPath, 'S-001')
    const listed = await listStories(backlogPath)
    assert.equal(listed.activeStoryId, 'S-001')
    assert.deepEqual((await getStoryTasks(backlogPath, 'S-001')).tasks.map((task) => task.id), ['T-01'])
    assert.equal((await readBacklog(backlogPath)).activeStoryId, 'S-001')
    assert.match(await readFile(backlogPath, 'utf8'), /S-001/)
  })
})

test('execution bundle services produce bounded, deterministic context and file scopes', async () => {
  await withTempDir(async (directory) => {
    const storyPath = join(directory, 'story.json')
    const dependencyPath = join(directory, 'dependencies.json')
    await writeFile(storyPath, JSON.stringify({
      storyId: 'S-010',
      title: 'Execution bundle',
      goal: 'Keep execution precise',
      spec: { scope: 'src/feature.ts', preserved_invariants: ['server authority'] },
      tasks: [{
        id: 'T-01',
        title: 'Implement',
        scope: ['src/feature.ts', 'docs/notes.md', 'scripts/ralph/runtime/log.txt'],
        checks: ['test -f src/feature.test.ts'],
        passes: false,
      }],
    }))
    await writeFile(dependencyPath, JSON.stringify([{ files_touched: ['src/dependency.ts'] }]))
    const contextPath = join(directory, 'context.json')
    await writeFile(contextPath, JSON.stringify({ dependency_handoff: [{ files_touched: ['src/dependency.ts'] }] }))
    const context = await buildExecutionContext(storyPath, dependencyPath)
    const files = await buildExecutionFiles(storyPath, contextPath)
    const checks = await buildExecutionChecks(storyPath)
    assert.deepEqual(context.pending_task_ids, ['T-01'])
    assert.deepEqual(files.writable_scope, ['src/feature.ts'])
    assert.deepEqual(files.nearest_tests, ['src/feature.test.ts'])
    assert.deepEqual(files.dependency_files, ['src/dependency.ts'])
    assert.deepEqual(checks[0].checks, ['test -f src/feature.test.ts'])
  })
})

test('project command discovery returns only supported package scripts', async () => {
  await withTempDir(async (directory) => {
    await writeFile(join(directory, 'package.json'), JSON.stringify({ scripts: { typecheck: 'tsc', test: 'jest', custom: 'x' } }))
    assert.deepEqual(await buildProjectCommandMap(directory), {
      typecheck: 'npm run typecheck',
      lint: null,
      test: 'npm run test',
      build: null,
    })
  })
})

test('harness process runner normalizes timeout exit and runtime environment', async () => {
  await withTempDir(async (directory) => {
    const code = await runHarnessProcess(process.execPath, ['-e', 'setTimeout(() => {}, 1000)'], {
      prompt: '',
      workspace: directory,
      timeoutMs: 20,
      stdin: false,
      environment: { RALPH_RUNTIME_HOME_DIR: join(directory, 'runtime') },
    })
    assert.equal(code, 124)
  })
})

test('check runner captures shell output and normalizes failures', async () => {
  await withTempDir(async (directory) => {
    const passed = await runCheck('printf success', directory)
    assert.deepEqual(passed, {
      passed: true,
      exitCode: 0,
      signal: null,
      timedOut: false,
      stdout: 'success',
      stderr: '',
    })

    const failed = await runCheck('printf failure >&2; exit 7', directory)
    assert.equal(failed.passed, false)
    assert.equal(failed.exitCode, 7)
    assert.equal(failed.stderr, 'failure')
  })
})

test('check runner enforces a bounded timeout', async () => {
  await withTempDir(async (directory) => {
    const result = await runCheck(`${process.execPath} -e "setTimeout(() => {}, 1000)"`, directory, { timeoutMs: 20 })
    assert.equal(result.passed, false)
    assert.equal(result.exitCode, 124)
    assert.equal(result.timedOut, true)
  })
})

test('check fingerprints use referenced files or sanitized task scope', async () => {
  await withTempDir(async (directory) => {
    const storyPath = join(directory, 'story.json')
    await mkdir(join(directory, 'src'), { recursive: true })
    await writeFile(join(directory, 'src', 'feature.ts'), 'feature')
    await writeFile(storyPath, JSON.stringify({
      storyId: 'S-011',
      tasks: [{ id: 'T-01', scope: ['src/feature.ts', 'docs/ignored.md'], checks: ['test -f src/feature.ts'] }],
    }))
    const referenced = await fingerprintCheck(storyPath, directory, 'T-01', 'test -f src/feature.ts')
    const scoped = await fingerprintCheck(storyPath, directory, 'T-01', 'npm test')
    assert.match(referenced, /^[0-9a-f]{40}$/)
    assert.equal(scoped, referenced)
  })
})

test('branch parent lookup uses the Git port', async () => {
  const git = {
    hasBranch: async () => true,
    createBranch: async () => {},
    checkout: async () => {},
    branchParent: async (branch) => branch === 'story/one' ? 'ralph/sprint/one' : '',
    setBranchParent: async () => {},
  }
  assert.equal(await getBranchParent({ git, branchName: 'story/one' }), 'ralph/sprint/one')
  assert.equal(await getBranchParent({ git, branchName: '' }), '')
})

test('story branch merge coordinates checkpoint, merge, and cleanup through Git port', async () => {
  const calls = []
  const git = {
    hasBranch: async (branch) => branch === 'story/one' || branch === 'ralph/sprint/one',
    createBranch: async () => {},
    checkout: async (branch) => calls.push(['checkout', branch]),
    branchParent: async () => '',
    setBranchParent: async () => {},
    stageAll: async () => calls.push(['stage']),
    hasCachedChanges: async () => true,
    commit: async (message) => calls.push(['commit', message]),
    mergeNoFastForward: async (branch, message) => calls.push(['merge', branch, message]),
    deleteBranch: async (branch) => calls.push(['delete', branch]),
  }
  const result = await mergeStoryBranch({
    git,
    storyBranch: 'story/one',
    mergeTarget: 'ralph/sprint/one',
    storyId: 'S-001',
    storyTitle: 'One',
  })
  assert.equal(result.status, 'merged')
  assert.deepEqual(calls, [
    ['stage'],
    ['commit', 'chore(ralph): checkpoint verified S-001 implementation'],
    ['checkout', 'ralph/sprint/one'],
    ['merge', 'story/one', 'merge: S-001 — One'],
    ['delete', 'story/one'],
  ])
})

test('sprint branch creation is idempotent and records its base branch', async () => {
  const calls = []
  const git = {
    hasBranch: async (branch) => branch === 'master',
    createBranch: async (branch, base) => calls.push(['create', branch, base]),
    checkout: async () => {},
    branchParent: async () => '',
    setBranchParent: async (branch, parent) => calls.push(['parent', branch, parent]),
  }
  assert.deepEqual(await ensureSprintBranch({ git, sprintBranch: 'ralph/sprint/one', baseBranch: 'master' }), {
    action: 'created', branch: 'ralph/sprint/one', parent: 'master',
  })
  assert.deepEqual(calls, [
    ['create', 'ralph/sprint/one', 'master'],
    ['parent', 'ralph/sprint/one', 'master'],
  ])
})

test('status reporting aggregates sprint, story, and branch state', async () => {
  await withTempDir(async (directory) => {
    const ralphRoot = join(directory, 'scripts', 'ralph')
    const sprintRoot = join(ralphRoot, 'sprints', 'sprint-one')
    const storyRoot = join(sprintRoot, 'stories', 'S-001')
    await mkdir(storyRoot, { recursive: true })
    await writeFile(join(sprintRoot, 'stories.json'), JSON.stringify({
      activeStoryId: 'S-001',
      stories: [{ id: 'S-001', title: 'One', status: 'active', priority: 1, effort: 2, story_path: 'scripts/ralph/sprints/sprint-one/stories/S-001/story.json' }],
    }))
    await writeFile(join(storyRoot, 'story.json'), JSON.stringify({ storyId: 'S-001', status: 'active', tasks: [] }))
    const report = await buildStatusReport({ workspaceRoot: directory, ralphRoot, activeSprint: 'sprint-one' })
    assert.equal(report.activeStory.id, 'S-001')
    assert.equal(report.worktree, 'clean')
    assert.match(renderStatusReport(report), /Active sprint: sprint-one/)
    assert.match(renderStatusReport(report), /Active story: S-001/)
  })
})

test('sprint state uses atomic JSON and active-sprint persistence', async () => {
  await withTempDir(async (directory) => {
    const storiesPath = join(directory, 'stories.json')
    const activePath = join(directory, '.active-sprint')
    await writeFile(storiesPath, JSON.stringify({ status: 'planned', stories: [] }))
    assert.equal(await getSprintStatus(storiesPath), 'planned')
    await setSprintStatus(storiesPath, 'ready')
    assert.equal(await getSprintStatus(storiesPath), 'ready')
    await setActiveSprint(activePath, 'sprint-one')
    assert.equal(await getActiveSprint(activePath), 'sprint-one')
  })
})

test('story container validation enforces identity, tasks, and shell-valid checks', async () => {
  await withTempDir(async (directory) => {
    const storyPath = join(directory, 'story.json')
    await writeFile(storyPath, JSON.stringify({ storyId: 'S-001', sprint: 'sprint-one', tasks: [{ id: 'T-01', checks: ['printf ok'] }] }))
    await validateStoryContainer(storyPath, 'S-001', 'sprint-one')
    await assert.rejects(() => validateStoryContainer(storyPath, 'S-002', 'sprint-one'), /storyId/)
  })
})

test('check inference derives unique project checks from legacy text', () => {
  assert.deepEqual(inferChecksFromText('Implement and test with typecheck, lint, and browser verification.'), [
    'npm run typecheck', 'npm test', 'npm run lint', 'echo browser verification required',
  ])
  assert.deepEqual(inferChecksFromText('No explicit acceptance criteria mentioned.'), ['npm run typecheck'])
})

test('preparation fingerprints are deterministic and sensitive to inputs', async () => {
  const options = {
    storyId: 'S-001', sprint: 'sprint-one', title: 'One', goal: 'Goal', promptContext: 'Context',
    commandMap: { test: 'npm test' }, dependsOn: ['S-000'], focusHints: '- `src/one.ts`', dependencyContext: 'Dependency',
  }
  const first = await computePrepFingerprint(options)
  assert.equal(first, await computePrepFingerprint({ ...options }))
  assert.notEqual(first, await computePrepFingerprint({ ...options, goal: 'Different' }))
  assert.match(first, /^[0-9a-f]{64}$/)
})

test('story health detects missing checks and invalid dependencies', async () => {
  await withTempDir(async (directory) => {
    const storyPath = join(directory, 'story.json')
    await writeFile(storyPath, JSON.stringify({ storyId: 'S-001', tasks: [{ id: 'T-01', title: 'Task', context: '', checks: [], depends_on: ['T-99'] }] }))
    const result = await analyzeStoryHealth(storyPath, 'S-001', 'planned')
    assert.equal(result.healthy, false)
    assert.match(result.messages.join('\n'), /no acceptance checks/)
    assert.match(result.messages.join('\n'), /not found in story/)
  })
})

test('preparation journal records atomic stage rollups and final status', async () => {
  await withTempDir(async (directory) => {
    await writeFile(join(directory, 'prepare-run.json'), JSON.stringify({ version: 1, stories: {} }))
    await recordPrepStage({ runDir: directory, storyId: 'S-001', stage: 'specify', status: 'passed', detail: 'ok', artifacts: ['spec.md'], durationMs: 12 })
    const rollup = await rollupPrepStages(directory)
    assert.equal(rollup.metrics.passed_stages, 1)
    assert.equal(rollup.stories['S-001'].specify.status, 'passed')
    await finalizePrepSummary(directory, 'passed')
    const summary = JSON.parse(await readFile(join(directory, 'prepare-run.json'), 'utf8'))
    assert.equal(summary.status, 'passed')
  })
})

test('fallow report normalizes issue counts and pass state', async () => {
  await withTempDir(async (directory) => {
    const reportPath = join(directory, 'fallow-report.json')
    await writeFallowReport({ reportPath, storyId: 'S-001', files: ['src/a.ts'], fallowIssues: 'unused-file: src/a.ts\nunused-export: a' })
    const report = JSON.parse(await readFile(reportPath, 'utf8'))
    assert.equal(report.issueCount, 2)
    assert.equal(report.passes, false)
    assert.deepEqual(report.files, ['src/a.ts'])
  })
})

test('runtime cleanup retains newest run directories', async () => {
  await withTempDir(async (directory) => {
    await mkdir(join(directory, '001'))
    await mkdir(join(directory, '002'))
    await mkdir(join(directory, '003'))
    const removed = await pruneRuntimeRuns(directory, 2)
    assert.deepEqual(removed, [join(directory, '001')])
    assert.equal((await readdir(directory)).sort().join(','), '002,003')
  })
})

test('archive retention compresses only entries beyond the keep count', async () => {
  await withTempDir(async (directory) => {
    const archive = join(directory, 'archive')
    await mkdir(join(archive, '001'), { recursive: true })
    await writeFile(join(archive, '001', 'record.txt'), 'archive')
    await mkdir(join(archive, '002'), { recursive: true })
    await writeFile(join(archive, '002', 'record.txt'), 'keep')
    const removed = await pruneArchiveRetention(archive, 1)
    assert.deepEqual(removed, [join(archive, '001.zip')])
    assert.equal((await readdir(archive)).sort().join(','), '001.zip,002')
  })
})

test('task check runner batches checks in one Node coordinator', async () => {
  await withTempDir(async (directory) => {
    const storyPath = join(directory, 'story.json')
    await writeFile(storyPath, JSON.stringify({ storyId: 'S-001', tasks: [{ id: 'T-01', checks: ['printf one', 'printf two'] }] }))
    const result = await runTaskChecks(storyPath, directory, 'T-01')
    assert.equal(result.passed, true)
    assert.deepEqual(result.checks.map((check) => check.stdout), ['one', 'two'])
  })
})

test('verification scope extraction honors task and story handoff boundaries', async () => {
  await withTempDir(async (directory) => {
    const storyPath = join(directory, 'story.json')
    await writeFile(storyPath, JSON.stringify({ storyId: 'S-001', story_handoff: { files_touched: ['src/a.ts'] }, tasks: [{ id: 'T-01', scope: ['src/b.ts'], handoff: { changed_files: ['src/c.ts'] } }] }))
    assert.deepEqual(await collectStoryScope(storyPath, 'T-01'), ['src/b.ts'])
    assert.deepEqual(await collectStoryScope(storyPath), ['src/a.ts', 'src/c.ts'])
  })
})
