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
const nodeNextIdCli = path.join(repoRoot, 'scripts/ralph/core/cli/next-id.mjs')
const nodeStatusCli = path.join(repoRoot, 'scripts/ralph/core/cli/update-story-status.mjs')
const nodeStartNextCli = path.join(repoRoot, 'scripts/ralph/core/cli/start-next.mjs')
const gitPort = path.join(repoRoot, 'scripts/ralph/core/ports/git.mjs')
const ensureStoryBranch = path.join(repoRoot, 'scripts/ralph/core/application/ensure-story-branch.mjs')
const ensureStoryBranchCli = path.join(repoRoot, 'scripts/ralph/core/cli/ensure-story-branch.mjs')
const codexExecCli = path.join(repoRoot, 'scripts/ralph/core/cli/codex-exec.mjs')
const piExecCli = path.join(repoRoot, 'scripts/ralph/core/cli/pi-exec.mjs')
const taskDomain = path.join(repoRoot, 'scripts/ralph/core/domain/task.mjs')
const verificationCli = path.join(repoRoot, 'scripts/ralph/core/cli/verification.mjs')
const updateStoryCli = path.join(repoRoot, 'scripts/ralph/core/cli/update-story.mjs')
const executionPlanCli = path.join(repoRoot, 'scripts/ralph/core/cli/execution-plan.mjs')
const executionContextCli = path.join(repoRoot, 'scripts/ralph/core/cli/execution-context.mjs')
const dependencyHandoffCli = path.join(repoRoot, 'scripts/ralph/core/cli/dependency-handoff.mjs')
const executionFilesCli = path.join(repoRoot, 'scripts/ralph/core/cli/execution-files.mjs')
const projectCommandsCli = path.join(repoRoot, 'scripts/ralph/core/cli/project-commands.mjs')
const storyRuntimeCli = path.join(repoRoot, 'scripts/ralph/core/cli/story-runtime.mjs')
const storyQueryCli = path.join(repoRoot, 'scripts/ralph/core/cli/story-query.mjs')
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

test('Node next-id core preserves the Bash command result on the same backlog fixture', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-next-id-parity-'))
  const storiesFile = path.join(root, 'stories.json')
  fs.writeFileSync(storiesFile, JSON.stringify({
    sprint: 'sprint-1',
    stories: [
      { id: 'S-001', priority: 1, status: 'ready', depends_on: ['S-003'] },
      { id: 'S-002', priority: 2, status: 'ready', depends_on: [] },
      { id: 'S-003', priority: 3, status: 'planned', depends_on: [] },
    ],
  }))

  const bashResult = spawnSync(storyScript, ['next-id'], {
    cwd: repoRoot,
    env: { ...process.env, RALPH_STORIES_FILE: storiesFile },
    encoding: 'utf8',
  })
  const nodeResult = spawnSync(process.execPath, [nodeNextIdCli, storiesFile], {
    cwd: repoRoot,
    encoding: 'utf8',
  })

  assert.equal(bashResult.status, 0, bashResult.stderr)
  assert.equal(nodeResult.status, 0, nodeResult.stderr)
  assert.equal(nodeResult.stdout, bashResult.stdout)
  assert.equal(nodeResult.stdout.trim(), 'S-002')
})

test('Node story status mutations preserve CLI output and write atomically', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-status-parity-'))
  const bashBacklog = path.join(root, 'bash-stories.json')
  const nodeBacklog = path.join(root, 'node-stories.json')
  const backlog = {
    sprint: 'sprint-1',
    stories: [{ id: 'S-001', priority: 1, status: 'ready', depends_on: [] }],
  }
  fs.writeFileSync(bashBacklog, JSON.stringify(backlog, null, 2) + '\n')
  fs.writeFileSync(nodeBacklog, JSON.stringify(backlog, null, 2) + '\n')

  const bashStatus = spawnSync(storyScript, ['set-status', 'S-001', 'active'], {
    cwd: repoRoot,
    env: { ...process.env, RALPH_STORIES_FILE: bashBacklog },
    encoding: 'utf8',
  })
  const nodeStatus = spawnSync(process.execPath, [nodeStatusCli, 'set-status', nodeBacklog, 'S-001', 'active'], {
    cwd: repoRoot,
    encoding: 'utf8',
  })
  assert.equal(bashStatus.status, 0, bashStatus.stderr)
  assert.equal(nodeStatus.status, 0, nodeStatus.stderr)
  assert.equal(nodeStatus.stdout, bashStatus.stdout)
  assert.deepEqual(JSON.parse(fs.readFileSync(nodeBacklog, 'utf8')), JSON.parse(fs.readFileSync(bashBacklog, 'utf8')))

  const nodeAbandon = spawnSync(process.execPath, [nodeStatusCli, 'abandon', nodeBacklog, 'S-001', 'blocked by dependency'], {
    cwd: repoRoot,
    encoding: 'utf8',
  })
  assert.equal(nodeAbandon.status, 0, nodeAbandon.stderr)
  assert.equal(JSON.parse(fs.readFileSync(nodeBacklog, 'utf8')).stories[0].abandonReason, 'blocked by dependency')
  assert.equal(fs.readdirSync(root).some((entry) => entry.endsWith('.tmp')), false)
})

test('Node start-next transition selects and activates the next story atomically', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-start-next-'))
  const storiesFile = path.join(root, 'stories.json')
  fs.writeFileSync(storiesFile, JSON.stringify({
    sprint: 'sprint-1',
    activeStoryId: null,
    stories: [
      { id: 'S-001', priority: 1, status: 'ready', depends_on: ['S-003'] },
      { id: 'S-002', priority: 2, status: 'ready', depends_on: [] },
      { id: 'S-003', priority: 3, status: 'done', depends_on: [] },
    ],
  }, null, 2) + '\n')

  const result = spawnSync(process.execPath, [nodeStartNextCli, storiesFile], {
    cwd: repoRoot,
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, 'S-001\n')
  const backlog = JSON.parse(fs.readFileSync(storiesFile, 'utf8'))
  assert.equal(backlog.activeStoryId, 'S-001')
  assert.equal(backlog.stories[0].status, 'active')
  assert.equal(fs.readdirSync(root).some((entry) => entry.endsWith('.tmp')), false)
})

test('story branch application uses the Git port without invoking Git directly', async () => {
  const { ensureStoryBranch: ensure } = await import(ensureStoryBranch)
  const calls = []
  const branches = new Set(['ralph/sprint/1'])
  const git = {
    async hasBranch(name) { return branches.has(name) },
    async createBranch(name, parent) { calls.push(['create', name, parent]); branches.add(name) },
    async checkout(name) { calls.push(['checkout', name]) },
    async branchParent() { return '' },
    async setBranchParent(name, parent) { calls.push(['parent', name, parent]) },
  }
  const result = await ensure({ git, storyBranch: 'ralph/story/S-001', sprintBranch: 'ralph/sprint/1' })
  assert.deepEqual(result, { action: 'create', branch: 'ralph/story/S-001', parent: 'ralph/sprint/1' })
  assert.deepEqual(calls, [
    ['create', 'ralph/story/S-001', 'ralph/sprint/1'],
    ['parent', 'ralph/story/S-001', 'ralph/sprint/1'],
  ])
})

test('process-backed Git adapter preserves story branch creation output', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-git-adapter-'))
  const run = (args) => spawnSync('git', ['-C', root, ...args], { encoding: 'utf8' })
  assert.equal(run(['init', '-q']).status, 0)
  assert.equal(run(['config', 'user.email', 'ralph@example.test']).status, 0)
  assert.equal(run(['config', 'user.name', 'Ralph Test']).status, 0)
  fs.writeFileSync(path.join(root, 'README.md'), 'fixture\n')
  assert.equal(run(['add', 'README.md']).status, 0)
  assert.equal(run(['commit', '-qm', 'fixture']).status, 0)
  assert.equal(run(['checkout', '-qb', 'ralph/sprint/1']).status, 0)

  const result = spawnSync(process.execPath, [ensureStoryBranchCli, root, 'ralph/story/S-001', 'ralph/sprint/1'], {
    cwd: repoRoot,
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, 'Created story branch: ralph/story/S-001 (from ralph/sprint/1)\n')
  assert.equal(run(['branch', '--show-current']).stdout.trim(), 'ralph/story/S-001')
  assert.equal(run(['for-each-ref', '--format=%(upstream:short)', 'refs/heads/ralph/story/S-001']).stdout.trim(), 'ralph/sprint/1')
})

test('Node Codex adapter preserves prompt, workspace, and selected flags', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-codex-adapter-'))
  const mock = path.join(root, 'mock-codex.sh')
  fs.writeFileSync(mock, '#!/bin/bash\nif [ "$1" = "--yolo" ] && [ "$2" = "exec" ] && [ "$3" = "--help" ]; then echo "Run Codex non-interactively"; exit 0; fi\nprintf "ARGS:%s\\n" "$*"\ncat\n')
  fs.chmodSync(mock, 0o755)
  const result = spawnSync(process.execPath, [codexExecCli, 'hello from ralph', root, '--model', 'fixture-model', '--', '--json'], {
    cwd: repoRoot,
    env: { ...process.env, CODEX_BIN: mock },
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /ARGS:--yolo exec --model fixture-model --json/)
  assert.match(result.stdout, /hello from ralph/)
})

test('Node Pi adapter preserves prompt, workspace, and selected flags', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-pi-adapter-'))
  const mock = path.join(root, 'mock-pi.sh')
  fs.writeFileSync(mock, '#!/bin/bash\nprintf "ARGS:%s\\n" "$*"\nprintf "ENV:%s\\n" "$PI_PERMISSION_LEVEL"\n')
  fs.chmodSync(mock, 0o755)
  const result = spawnSync(process.execPath, [piExecCli, 'hello from pi', root, '--mode', 'json', '--', '--verbose'], {
    cwd: repoRoot,
    env: { ...process.env, PI_BIN: mock },
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /ARGS:-p --mode json --verbose hello from pi/)
  assert.match(result.stdout, /ENV:bypassed/)
})

test('Node task domain preserves dependency blocking and completion rules', async () => {
  const {
    applyTaskResult,
    storyIsComplete,
    taskDependenciesMet,
    verificationDecision,
  } = await import(taskDomain)
  let story = {
    status: 'active',
    passes: false,
    tasks: [
      { id: 'T-001', status: 'pending', passes: false, depends_on: [] },
      { id: 'T-002', status: 'pending', passes: false, depends_on: ['T-001'] },
      { id: 'T-003', status: 'pending', passes: false, depends_on: ['T-404'] },
    ],
  }
  assert.equal(taskDependenciesMet(story, 'T-002'), false)
  assert.deepEqual(verificationDecision(story, 'T-002'), { state: 'blocked', failureSeen: true })
  story = applyTaskResult(story, 'T-001', true)
  assert.equal(taskDependenciesMet(story, 'T-002'), true)
  assert.deepEqual(verificationDecision(story, 'T-002'), { state: 'ready', failureSeen: false })
  story = applyTaskResult(story, 'T-002', true)
  story = applyTaskResult(story, 'T-003', true)
  story = { ...story, status: 'done', passes: true }
  assert.equal(storyIsComplete(story), true)
})

test('verification CLI matches task-domain decisions and story completion exit codes', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-verification-cli-'))
  const storyPath = path.join(root, 'story.json')
  fs.writeFileSync(storyPath, JSON.stringify({
    status: 'done',
    passes: true,
    tasks: [{ id: 'T-001', status: 'done', passes: true, depends_on: [] }],
  }))
  const complete = spawnSync(process.execPath, [verificationCli, 'story-complete', storyPath], { encoding: 'utf8' })
  assert.equal(complete.status, 0, complete.stderr)
  const decision = spawnSync(process.execPath, [verificationCli, 'task-decision', storyPath, 'T-001', 'false'], { encoding: 'utf8' })
  assert.equal(decision.status, 0, decision.stderr)
  assert.equal(decision.stdout, 'ready\n')
})

test('Node story result mutations write atomically and preserve CLI state', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-story-write-'))
  const storyPath = path.join(root, 'story.json')
  fs.writeFileSync(storyPath, JSON.stringify({
    status: 'active', passes: false,
    tasks: [{ id: 'T-001', status: 'pending', passes: false, depends_on: [] }],
  }) + '\n')
  const result = spawnSync(process.execPath, [updateStoryCli, 'set-task-result', storyPath, 'T-001', 'true'], { encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  const handoff = spawnSync(process.execPath, [updateStoryCli, 'set-task-field', storyPath, 'T-001', 'handoff', '{"artifacts":["src/a.js"]}'], { encoding: 'utf8' })
  assert.equal(handoff.status, 0, handoff.stderr)
  const complete = spawnSync(process.execPath, [updateStoryCli, 'complete', storyPath], { encoding: 'utf8' })
  assert.equal(complete.status, 0, complete.stderr)
  const story = JSON.parse(fs.readFileSync(storyPath, 'utf8'))
  assert.equal(story.status, 'done')
  assert.equal(story.tasks[0].status, 'done')
  assert.deepEqual(story.tasks[0].handoff, { artifacts: ['src/a.js'] })
  assert.equal(fs.readdirSync(root).some((entry) => entry.endsWith('.tmp')), false)
})

test('execution plan CLI preserves pending task and target filtering', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-execution-plan-'))
  const storyPath = path.join(root, 'story.json')
  fs.writeFileSync(storyPath, JSON.stringify({ tasks: [
    { id: 'T-001', title: 'done', passes: true, checks: ['true'] },
    { id: 'T-002', title: 'pending', passes: false, depends_on: ['T-001'], checks: ['npm test'] },
    { id: 'T-003', title: 'other', status: 'failed', checks: [] },
  ] }))
  const result = spawnSync(process.execPath, [executionPlanCli, 'checks', storyPath, 'T-002'], { encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(JSON.parse(result.stdout), [{
    id: 'T-002', title: 'pending', depends_on: ['T-001'], checks: ['npm test'],
  }])
})

test('execution context CLI preserves story metadata and dependency handoff shape', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-execution-context-'))
  const storyPath = path.join(root, 'story.json')
  const dependenciesPath = path.join(root, 'dependencies.json')
  fs.writeFileSync(storyPath, JSON.stringify({
    storyId: 'S-001', title: 'Fixture story', goal: 'Do the work',
    spec: { scope: 'src/', preserved_invariants: ['compatibility'] },
    tasks: [{ id: 'T-001', passes: false }],
  }))
  fs.writeFileSync(dependenciesPath, JSON.stringify([{ id: 'S-000', title: 'Prior', files_touched: ['src/a.js'] }]))
  const result = spawnSync(process.execPath, [executionContextCli, storyPath, dependenciesPath, 'T-001'], { encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(JSON.parse(result.stdout), {
    storyId: 'S-001', title: 'Fixture story', goal: 'Do the work', scope: 'src/',
    preserved_invariants: ['compatibility'],
    dependency_handoff: [{ id: 'S-000', title: 'Prior', files_touched: ['src/a.js'] }],
    pending_task_ids: ['T-001'], target_task_id: 'T-001',
  })
})

test('dependency handoff CLI preserves completed dependency metadata', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-dependency-handoff-'))
  const storyPath = path.join(root, 'current.json')
  const dependencyPath = path.join(root, 'dependency.json')
  const backlogPath = path.join(root, 'stories.json')
  fs.writeFileSync(storyPath, JSON.stringify({ depends_on: ['S-000'] }))
  fs.writeFileSync(dependencyPath, JSON.stringify({ title: 'Prior story', story_handoff: {
    files_touched: ['src/a.js'], contracts_added: ['API contract'], residual_risks: ['none'],
  } }))
  fs.writeFileSync(backlogPath, JSON.stringify({ stories: [{ id: 'S-000', story_path: 'dependency.json' }] }))
  const result = spawnSync(process.execPath, [dependencyHandoffCli, storyPath, backlogPath, root], { encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(JSON.parse(result.stdout), [{
    id: 'S-000', title: 'Prior story', files_touched: ['src/a.js'],
    contracts_added: ['API contract'], residual_risks: ['none'],
  }])
})

test('execution files CLI preserves scope/test extraction and safety filters', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-execution-files-'))
  const storyPath = path.join(root, 'story.json')
  const contextPath = path.join(root, 'context.json')
  fs.writeFileSync(storyPath, JSON.stringify({ tasks: [{
    id: 'T-001', passes: false, scope: ['src/a.js', 'docs/guide.md', 'node_modules/x.js'],
    checks: ['test -f src/a.test.js', 'grep -n needle src/a.js'],
  }] }))
  fs.writeFileSync(contextPath, JSON.stringify({ dependency_handoff: [{ files_touched: ['src/dependency.js', 'coverage/out'] }] }))
  const result = spawnSync(process.execPath, [executionFilesCli, storyPath, contextPath], { encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(JSON.parse(result.stdout), {
    writable_scope: ['src/a.js'],
    nearest_tests: ['src/a.test.js', 'src/a.js'],
    dependency_files: ['src/dependency.js'],
    blocked_paths: [
      'node_modules/**', '.next/**', 'coverage/**', 'dist/**', 'build/**',
      'vendor/**', 'scripts/ralph/runtime/**', 'dist-docs/**',
      'scripts/ralph/README-local.md', 'scripts/ralph/doctor.sh',
      'scripts/ralph/lib/specify.sh',
    ],
  })
})

test('project command CLI preserves supported package script mappings', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-project-commands-'))
  fs.writeFileSync(path.join(root, 'package.json'), JSON.stringify({ scripts: {
    test: 'node --test', lint: 'eslint .', build: 'tsc', ignored: 'noop',
  } }))
  const result = spawnSync(process.execPath, [projectCommandsCli, root], { encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(JSON.parse(result.stdout), {
    typecheck: null, lint: 'npm run lint', test: 'npm run test', build: 'npm run build',
  })
})

test('story runtime CLI writes an atomic manifest with normalized fields', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-story-runtime-'))
  const manifestPath = path.join(root, 'story-summary.json')
  const values = [
    'S-001', 'Fixture', '/tmp/story.json', '/tmp/runtime', '/tmp/logs', 'verifying',
    '2026-01-01T00:00:00Z', '2026-01-01T00:01:00Z', '2026-01-01T00:00:30Z',
    'T-001', 'npm test', 'Verified task T-001', '', '', '', '1', '2', '3', '4000', '{"harness":"codex"}',
  ]
  const result = spawnSync(process.execPath, [storyRuntimeCli, manifestPath, ...values], { encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
  assert.equal(manifest.story_id, 'S-001')
  assert.equal(manifest.current_check_index, 2)
  assert.deepEqual(manifest.execution_profile, { harness: 'codex' })
  assert.equal(fs.readdirSync(root).some((entry) => entry.endsWith('.tmp')), false)
})

test('story query CLI preserves task reads and metadata', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-story-query-'))
  const storyPath = path.join(root, 'story.json')
  fs.writeFileSync(storyPath, JSON.stringify({ storyId: 'S-001', title: 'Fixture', branchName: 'story/S-001', tasks: [
    { id: 'T-001', status: 'done', passes: true, checks: ['true'] },
    { id: 'T-002', status: 'pending', passes: false, checks: ['npm test'] },
  ] }))
  const checks = spawnSync(process.execPath, [storyQueryCli, 'task-checks', storyPath, 'T-002'], { encoding: 'utf8' })
  assert.equal(checks.status, 0, checks.stderr)
  assert.deepEqual(JSON.parse(checks.stdout), ['npm test'])
  const metadata = spawnSync(process.execPath, [storyQueryCli, 'metadata', storyPath], { encoding: 'utf8' })
  assert.equal(metadata.status, 0, metadata.stderr)
  assert.deepEqual(JSON.parse(metadata.stdout), { storyId: 'S-001', title: 'Fixture', branchName: 'story/S-001', agent: '' })
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

test('ralph-story add accepts an empty dependency list under strict mode', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-story-add-'))
  const runtimeRoot = path.join(root, 'scripts/ralph')
  const storiesFile = path.join(runtimeRoot, 'backlog/sprint-1/stories.json')
  fs.cpSync(path.join(repoRoot, 'scripts/ralph'), runtimeRoot, { recursive: true })
  fs.mkdirSync(path.dirname(storiesFile), { recursive: true })
  fs.writeFileSync(path.join(runtimeRoot, '.active-sprint'), 'sprint-1\n')
  fs.writeFileSync(storiesFile, JSON.stringify({
    sprint: 'sprint-1', activeStoryId: null, stories: [],
  }))

  const result = spawnSync(path.join(runtimeRoot, 'ralph-story.sh'), ['add', '--title', 'No dependencies'], {
    cwd: root,
    env: { ...process.env, RALPH_STORIES_FILE: storiesFile },
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  const story = JSON.parse(fs.readFileSync(storiesFile, 'utf8')).stories[0]
  assert.deepEqual(story.depends_on, [])
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
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/lib/provider-env.sh')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/cli/next-id.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/cli/update-story-status.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/cli/start-next.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/cli/ensure-story-branch.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/cli/codex-exec.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/cli/pi-exec.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/cli/verification.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/cli/update-story.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/cli/execution-plan.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/cli/execution-context.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/cli/dependency-handoff.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/cli/execution-files.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/cli/project-commands.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/cli/story-runtime.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/cli/story-query.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/domain/sprint.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/domain/story.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/domain/task.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/application/select-next-story.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/application/update-story-status.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/application/start-next-story.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/application/ensure-story-branch.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/repositories/backlog-repository.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/repositories/story-repository.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/application/verification.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/application/update-story.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/application/execution-plan.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/application/execution-context.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/application/dependency-handoff.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/application/execution-files.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/application/project-commands.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/application/story-runtime.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/application/story-query.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/repositories/runtime-repository.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/domain/paths.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/ports/git.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/adapters/git-process.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/adapters/codex-process.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/adapters/pi-process.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/core/ports/harness.mjs')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/commands/story/generation.sh')), true)
  assert.equal(fs.existsSync(path.join(root, 'scripts/ralph/commands/story/specification.sh')), true)
})
