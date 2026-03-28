const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { execFileSync } = require('node:child_process')

const REPO_ROOT = path.resolve(__dirname, '..')

function run(cmd, args, { cwd, env } = {}) {
  return execFileSync(cmd, args, {
    cwd,
    env: {
      ...process.env,
      ...env,
    },
    encoding: 'utf8',
    stdio: 'pipe',
  })
}

function writeFile(targetPath, contents) {
  fs.mkdirSync(path.dirname(targetPath), { recursive: true })
  fs.writeFileSync(targetPath, contents)
}

function buildLoopHandoff({ status = 'completed', completionSignal = true, storyId = 'US-001', storyTitle = 'Stub story' } = {}) {
  return [
    '<ralph_handoff>',
    JSON.stringify({
      status,
      story: {
        id: storyId,
        title: storyTitle,
      },
      summary: 'Stub loop completed.',
      errors: [],
      directionChanges: [],
      verification: ['Stub verification passed.'],
      filesChanged: ['src/allowed.ts'],
      assumptions: [],
      nextLoopAdvice: [],
      completionSignal,
    }),
    '</ralph_handoff>',
    '',
  ].join('\n')
}

function chmodScripts(rootDir) {
  const stack = [rootDir]
  while (stack.length > 0) {
    const current = stack.pop()
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const fullPath = path.join(current, entry.name)
      if (entry.isDirectory()) {
        stack.push(fullPath)
        continue
      }
      if (entry.name.endsWith('.sh')) {
        fs.chmodSync(fullPath, 0o755)
      }
    }
  }
}

function installCodexStub(repoDir) {
  const binDir = path.join(repoDir, 'bin')
  const stubPath = path.join(binDir, 'codex')
  fs.mkdirSync(binDir, { recursive: true })
  writeFile(
    stubPath,
    `#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const args = process.argv.slice(2);
function buildLoopReadyMarkdown(title = 'Stub story') {
  return [
    '# PRD',
    '',
    '## Scope',
    '- Deliver the requested stub workflow without broadening into unrelated framework changes.',
    '',
    '## Out of Scope',
    '- No unrelated cleanup or roadmap reshaping.',
    '',
    '## Execution Model',
    '- Start with the first slice in the exact source file path named below, keep support scope limited, and verify the slice before widening.',
    '- Verification must prove the slice through typecheck, lint, and tests before Ralph advances.',
    '',
    '## First Slice Expectations',
    '- Exact source entrypoint: scripts/ralph/tasks/stub-input.md.',
    '- Destination workflow: update the generated PRD markdown and then convert it into scripts/ralph/prd.json.',
    '- Commands to prove the slice: run typecheck, lint, and tests for the changed workflow.',
    '',
    '## Allowed Supporting Files',
    '- package.json test and lint scripts are in scope when verification wiring needs to remain intact.',
    '- Verification scripts, config files, and workflow helpers under scripts/ are allowed when they are required by the slice.',
    '',
    '## Preserved Invariants',
    '- Existing Ralph workflow contracts remain stable and unchanged outside the requested slice.',
    '- The generated plan must preserve canonical branch naming and intact verification expectations.',
    '',
    '## User Stories',
    '',
    '### Story US-001: ' + title,
    'Acceptance Criteria',
    '- Must update the exact source slice with execution-ready detail.',
    '- Must preserve the required support-file workflow and verification commands.',
    '- Must prove the result with typecheck, lint, and tests.',
    '',
    '## Refinement Checkpoints',
    '- Confirm the first slice stays inside the named workflow and support scope.',
    '',
    '## Definition of Done',
    '- Verification remains intact and the PRD is ready for Ralph loop execution.',
    '',
  ].join('\\n');
}
if (args.includes('--help')) {
  process.stdout.write('Run Codex non-interactively\\n');
  process.exit(0);
}
const cwd = process.cwd();
const loopMode = process.env.RALPH_TEST_LOOP_MODE || '';
const input = fs.readFileSync(0, 'utf8');
  if (input.includes('You are the coding agent for one Ralph loop iteration.') && loopMode) {
  const prdPath = path.join(cwd, 'scripts/ralph/prd.json');
  const progressPath = path.join(cwd, 'scripts/ralph/progress.txt');
  if (loopMode === 'codex-fail') {
    process.stderr.write('codex stub failure\\n');
    process.exit(17);
  }
  if (loopMode === 'scope-valid') {
    fs.writeFileSync(path.join(cwd, 'src/allowed.ts'), 'export const allowed = "updated";\\n');
    fs.mkdirSync(path.join(cwd, 'tests'), { recursive: true });
    fs.writeFileSync(path.join(cwd, 'tests/browser.test.mjs'), 'console.log("browser ok");\\n');
    require('child_process').execFileSync('git', ['add', 'src/allowed.ts', 'tests/browser.test.mjs'], { cwd, stdio: 'pipe' });
    require('child_process').execFileSync('git', ['commit', '-m', 'feat: [US-001] - Scoped valid change'], { cwd, stdio: 'pipe' });
  } else if (loopMode === 'scope-helper-invalid') {
    fs.mkdirSync(path.join(cwd, 'scripts'), { recursive: true });
    fs.writeFileSync(path.join(cwd, 'scripts/browser-check.mjs'), 'console.log("helper tweak");\\n');
    require('child_process').execFileSync('git', ['add', 'scripts/browser-check.mjs'], { cwd, stdio: 'pipe' });
    require('child_process').execFileSync('git', ['commit', '-m', 'feat: [US-001] - Helper edit'], { cwd, stdio: 'pipe' });
  } else if (loopMode === 'scope-uncommitted') {
    fs.writeFileSync(path.join(cwd, 'src/disallowed.ts'), 'export const disallowed = "oops";\\n');
  } else if (loopMode === 'scope-invalid') {
    fs.writeFileSync(path.join(cwd, 'src/disallowed.ts'), 'export const disallowed = "oops";\\n');
    require('child_process').execFileSync('git', ['add', 'src/disallowed.ts'], { cwd, stdio: 'pipe' });
    require('child_process').execFileSync('git', ['commit', '-m', 'feat: [US-001] - Scoped invalid change'], { cwd, stdio: 'pipe' });
  }

  if (fs.existsSync(prdPath) && loopMode !== 'invalid-handoff') {
    const prd = JSON.parse(fs.readFileSync(prdPath, 'utf8'));
    if (Array.isArray(prd.userStories) && prd.userStories[0]) {
      prd.userStories[0].passes = true;
    }
    fs.writeFileSync(prdPath, JSON.stringify(prd, null, 2));
  }
  fs.appendFileSync(
    progressPath,
    '\\n## 2026-03-22 17:30:00 EDT - US-001\\n- Implemented: Stub loop change\\n---\\n'
  );
  if (loopMode === 'missing-handoff-complete') {
    fs.appendFileSync(
      progressPath,
      '\\n## 2026-03-22 17:30:01 EDT - Completion\\n- Full verification: ./scripts/ralph/ralph-verify.sh --full passed\\n---\\n'
    );
  } else if (loopMode === 'strict-complete-no-note') {
    fs.appendFileSync(
      progressPath,
      '- Full verification: ./scripts/ralph/ralph-verify.sh --full passed\\n'
    );
    process.stdout.write(${JSON.stringify(buildLoopHandoff())});
  } else if (loopMode === 'invalid-handoff') {
    process.stdout.write('<ralph_handoff>\\n{"status":"completed","completionSignal":true}\\n</ralph_handoff>\\n');
  } else if (loopMode === 'multi-handoff') {
    fs.appendFileSync(
      progressPath,
      '\\n## [2026-03-22 17:30:01 EDT] - COMPLETE\\n- Full verification: ./scripts/ralph/ralph-verify.sh --full passed\\n---\\n'
    );
    process.stdout.write('<ralph_handoff>\\n{"status":"no_change","story":{"id":"US-000","title":"Example"},"summary":"Prompt example.","errors":[],"directionChanges":[],"verification":[],"filesChanged":[],"assumptions":[],"nextLoopAdvice":[],"completionSignal":false}\\n</ralph_handoff>\\n');
    process.stdout.write(${JSON.stringify(buildLoopHandoff())});
  } else if (loopMode === 'invalid-completion-schema') {
    if (fs.existsSync(prdPath)) {
      const prd = JSON.parse(fs.readFileSync(prdPath, 'utf8'));
      if (Array.isArray(prd.userStories)) {
        for (const story of prd.userStories) story.passes = true;
        fs.writeFileSync(prdPath, JSON.stringify(prd, null, 2));
      }
    }
    fs.appendFileSync(
      progressPath,
      '\\n## [2026-03-22 17:30:01 EDT] - [US-002]\\n- Implemented: Completed second story\\n- Full verification: ./scripts/ralph/ralph-verify.sh --full passed\\n---\\n'
    );
    process.stdout.write('<ralph_handoff>\\n' + JSON.stringify({
      status: 'completed',
      story: { id: 'US-002', title: 'Second story' },
      summary: 'Completed the second story.',
      errors: [],
      directionChanges: [],
      verification: ['targeted passed', 'browser passed', 'full passed', 'post-check passed'],
      filesChanged: ['src/render.ts'],
      assumptions: [],
      nextLoopAdvice: [],
      completionSignal: true,
    }) + '\\n</ralph_handoff>\\n');
  } else if (loopMode === 'three-verification-completion') {
    if (fs.existsSync(prdPath)) {
      const prd = JSON.parse(fs.readFileSync(prdPath, 'utf8'));
      if (Array.isArray(prd.userStories)) {
        for (const story of prd.userStories) story.passes = true;
        fs.writeFileSync(prdPath, JSON.stringify(prd, null, 2));
      }
    }
    fs.appendFileSync(
      progressPath,
      '\\n## [2026-03-22 17:30:01 EDT] - [US-002]\\n- Implemented: Completed second story\\n- Full verification: ./scripts/ralph/ralph-verify.sh --full passed\\n---\\n'
    );
    process.stdout.write('<ralph_handoff>\\n' + JSON.stringify({
      status: 'completed',
      story: { id: 'US-002', title: 'Second story' },
      summary: 'Completed the second story.',
      errors: [],
      directionChanges: [],
      verification: ['targeted passed', 'browser passed', 'full passed'],
      filesChanged: ['src/render.ts'],
      assumptions: [],
      nextLoopAdvice: [],
      completionSignal: true,
    }) + '\\n</ralph_handoff>\\n');
  } else {
    fs.appendFileSync(
      progressPath,
      '\\n## [2026-03-22 17:30:01 EDT] - COMPLETE\\n- Full verification: ./scripts/ralph/ralph-verify.sh --full passed\\n---\\n'
    );
    process.stdout.write(${JSON.stringify(buildLoopHandoff())});
  }
}
if (input.includes('Convert this PRD markdown file into Ralph JSON')) {
  const destination = (input.match(/Destination: \`([^\\\`]+)\`/) || [null, 'scripts/ralph/prd.json'])[1];
  const branchName = (input.match(/Set \`branchName\` to: \`([^\\\`]+)\`/) || [null, 'ralph/test/epic-001'])[1];
  const output = {
    project: 'tmp-ralph-test',
    branchName,
    description: 'Generated by codex stub',
    userStories: [
      {
        id: 'US-001',
        title: 'Stub story',
        description: 'Stub story',
        acceptanceCriteria: ['Tests pass'],
        priority: 1,
        passes: false,
        notes: ''
      }
    ]
  };
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, JSON.stringify(output, null, 2));
}
if (input.includes('Generate a complete PRD markdown from this epic context and write it to:')) {
  const destination = (input.match(/write it to:\\n\`([^\\\`]+)\`/) || [null, 'scripts/ralph/tasks/sprint-test/prd-epic-001.md'])[1];
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, buildLoopReadyMarkdown('Stub story'));
}
if (input.includes('Strengthen this existing PRD markdown in place so it becomes loop-ready for Ralph:')) {
  const destination = (input.match(/Ralph:\\n\`([^\\\`]+)\`/) || [null, 'scripts/ralph/tasks/sprint-test/prd-epic-001.md'])[1];
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, buildLoopReadyMarkdown('Strengthened stub story'));
  process.stdout.write('Status: strengthened\\nReason: Added loop-ready execution details.\\n');
}
if (input.includes('Create a complete Ralph planning package') || input.includes('Create a compact Ralph planning package')) {
  const markdownPath = 'scripts/ralph/tasks/prds/prd-stub-feature.md';
  const jsonPath = 'scripts/ralph/prd.json';
  fs.mkdirSync(path.dirname(markdownPath), { recursive: true });
  fs.writeFileSync(markdownPath, buildLoopReadyMarkdown('Stub story'));
  fs.mkdirSync(path.dirname(jsonPath), { recursive: true });
  fs.writeFileSync(jsonPath, JSON.stringify({
    project: 'tmp-ralph-test',
    branchName: 'ralph/test/standalone',
    description: 'Generated by codex stub',
    userStories: [
      {
        id: 'US-001',
        title: 'Stub story',
        description: 'Stub story',
        acceptanceCriteria: ['Typecheck passes', 'Lint passes', 'Tests pass'],
        priority: 1,
        passes: false,
        notes: ''
      }
    ]
  }, null, 2));
}
`
  )
  fs.chmodSync(stubPath, 0o755)
  return `${binDir}:${process.env.PATH}`
}

function initTempRepo() {
  const repoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-run-state-'))
  const frameworkRoot = path.join(repoDir, 'scripts', 'ralph')
  fs.mkdirSync(path.dirname(frameworkRoot), { recursive: true })
  fs.cpSync(REPO_ROOT, frameworkRoot, {
    recursive: true,
    filter: (sourcePath) => !sourcePath.includes(`${path.sep}.git${path.sep}`) && !sourcePath.endsWith(`${path.sep}.git`),
  })
  chmodScripts(frameworkRoot)

  writeFile(
    path.join(repoDir, '.gitignore'),
    [
      'scripts/ralph/.last-branch',
      'scripts/ralph/.active-sprint',
      'scripts/ralph/.active-prd',
      'scripts/ralph/prd.json',
      'scripts/ralph/progress.txt',
      'scripts/ralph/.completion-state.json',
      'scripts/ralph/.iteration-log*.txt',
      'scripts/ralph/.iteration-handoff*.json',
      '.playwright-cli/',
      'bin/',
    ].join('\n') + '\n'
  )

  run('git', ['init', '-b', 'master'], { cwd: repoDir })
  run('git', ['config', 'user.name', 'Ralph Test'], { cwd: repoDir })
  run('git', ['config', 'user.email', 'ralph-test@example.com'], { cwd: repoDir })
  run('git', ['add', '.'], { cwd: repoDir })
  run('git', ['commit', '-m', 'init'], { cwd: repoDir })
  return repoDir
}

test('ralph-prime resets stale progress and run artifacts for a new epic', () => {
  const repoDir = initTempRepo()
  const env = { PATH: installCodexStub(repoDir) }

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-test\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-test/epics.json'),
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        activeEpicId: null,
        epics: [
          {
            id: 'EPIC-001',
            title: 'EPIC Test',
            priority: 1,
            status: 'planned',
            dependsOn: [],
            prdPaths: ['scripts/ralph/tasks/sprint-test/prd-epic-001.md'],
            goal: 'Test goal',
          },
        ],
      },
      null,
      2
    )
  )
  writeFile(path.join(repoDir, 'scripts/ralph/tasks/sprint-test/prd-epic-001.md'), '# Test PRD\n')
  writeFile(path.join(repoDir, 'scripts/ralph/prd.json'), '{}\n')
  writeFile(path.join(repoDir, 'scripts/ralph/progress.txt'), 'STALE PROGRESS\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.completion-state.json'), '{"status":"completed","completionSignal":true,"iteration":1,"branch":"ralph/stale","recordedAt":"2026-03-22T17:30:00-04:00"}\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-log-latest.txt'), 'STALE TRANSCRIPT\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-log-iter-1.txt'), 'STALE ITER TRANSCRIPT\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-handoff-latest.json'), '{"status":"no_change","summary":"stale","completionSignal":false,"errors":[],"directionChanges":[],"verification":[],"filesChanged":[],"assumptions":[],"nextLoopAdvice":[]}\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-handoff-iter-1.json'), '{"status":"no_change","summary":"stale","completionSignal":false,"errors":[],"directionChanges":[],"verification":[],"filesChanged":[],"assumptions":[],"nextLoopAdvice":[]}\n')
  fs.mkdirSync(path.join(repoDir, '.playwright-cli'), { recursive: true })

  run('./scripts/ralph/ralph-prime.sh', ['--auto'], { cwd: repoDir, env })

  const progress = fs.readFileSync(path.join(repoDir, 'scripts/ralph/progress.txt'), 'utf8')
  assert.match(progress, /# Ralph Progress Log/)
  assert.ok(!progress.includes('STALE PROGRESS'))
  assert.equal(fs.existsSync(path.join(repoDir, 'scripts/ralph/.iteration-log-latest.txt')), false)
  assert.equal(fs.existsSync(path.join(repoDir, 'scripts/ralph/.iteration-log-iter-1.txt')), false)
  assert.equal(fs.existsSync(path.join(repoDir, 'scripts/ralph/.iteration-handoff-latest.json')), false)
  assert.equal(fs.existsSync(path.join(repoDir, 'scripts/ralph/.iteration-handoff-iter-1.json')), false)
  assert.equal(fs.existsSync(path.join(repoDir, 'scripts/ralph/.completion-state.json')), false)
  assert.equal(fs.existsSync(path.join(repoDir, '.playwright-cli')), false)

  const primed = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/prd.json'), 'utf8'))
  assert.equal(primed.branchName, 'ralph/sprint-test/epic-001')
})

test('ralph-sprint next returns the lowest-numbered unfinished sprint', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/epics.json'),
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        sprint: 'sprint-1',
        activeEpicId: null,
        epics: [
          {
            id: 'EPIC-001',
            title: 'Finished epic',
            priority: 1,
            status: 'done',
            dependsOn: [],
            prdPaths: ['scripts/ralph/tasks/sprint-1/prd-epic-001.md'],
            goal: 'Done',
          },
        ],
      },
      null,
      2
    )
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-2/epics.json'),
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        sprint: 'sprint-2',
        activeEpicId: null,
        epics: [
          {
            id: 'EPIC-001',
            title: 'Planned epic',
            priority: 1,
            status: 'planned',
            dependsOn: [],
            prdPaths: ['scripts/ralph/tasks/sprint-2/prd-epic-001.md'],
            goal: 'Next',
          },
        ],
      },
      null,
      2
    )
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-10/epics.json'),
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        sprint: 'sprint-10',
        activeEpicId: null,
        epics: [
          {
            id: 'EPIC-001',
            title: 'Later epic',
            priority: 1,
            status: 'planned',
            dependsOn: [],
            prdPaths: ['scripts/ralph/tasks/sprint-10/prd-epic-001.md'],
            goal: 'Later',
          },
        ],
      },
      null,
      2
    )
  )

  const output = run('./scripts/ralph/ralph-sprint.sh', ['next'], { cwd: repoDir })
  assert.equal(output.trim(), 'sprint-2')
})

test('ralph-sprint next --activate selects and activates the next unfinished sprint', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/epics.json'),
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        sprint: 'sprint-1',
        activeEpicId: null,
        epics: [
          {
            id: 'EPIC-001',
            title: 'Finished epic',
            priority: 1,
            status: 'done',
            dependsOn: [],
            prdPaths: ['scripts/ralph/tasks/sprint-1/prd-epic-001.md'],
            goal: 'Done',
          },
        ],
      },
      null,
      2
    )
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-2/epics.json'),
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        sprint: 'sprint-2',
        activeEpicId: null,
        epics: [
          {
            id: 'EPIC-001',
            title: 'Active sprint epic',
            priority: 1,
            status: 'ready',
            dependsOn: [],
            prdPaths: ['scripts/ralph/tasks/sprint-2/prd-epic-001.md'],
            goal: 'Activate',
          },
        ],
      },
      null,
      2
    )
  )

  const output = run('./scripts/ralph/ralph-sprint.sh', ['next', '--activate'], { cwd: repoDir })
  assert.match(output, /^sprint-2$/m)
  assert.match(output, /Active sprint set to: sprint-2/)
  assert.match(output, /Checked out sprint branch: ralph\/sprint\/sprint-2/)
  assert.equal(fs.readFileSync(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'utf8'), 'sprint-2\n')
  assert.equal(run('git', ['branch', '--show-current'], { cwd: repoDir }).trim(), 'ralph/sprint/sprint-2')
})

test('ralph-sprint next skips historic blocked-only sprints before the roadmap baseline', () => {
  const repoDir = initTempRepo()

  writeFile(
    path.join(repoDir, 'scripts/ralph/roadmap.json'),
    JSON.stringify(
      {
        sprints: [
          { name: 'sprint-3' },
          { name: 'sprint-4' },
        ],
      },
      null,
      2
    )
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-1/epics.json'),
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        sprint: 'sprint-1',
        activeEpicId: null,
        epics: [
          {
            id: 'EPIC-001',
            title: 'Historic blocked epic',
            priority: 1,
            status: 'blocked',
            dependsOn: [],
            prdPaths: ['scripts/ralph/tasks/sprint-1/prd-epic-001.md'],
            goal: 'Blocked historic work',
          },
        ],
      },
      null,
      2
    )
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-3/epics.json'),
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        sprint: 'sprint-3',
        activeEpicId: null,
        epics: [
          {
            id: 'EPIC-001',
            title: 'Baseline sprint epic',
            priority: 1,
            status: 'planned',
            dependsOn: [],
            prdPaths: ['scripts/ralph/tasks/sprint-3/prd-epic-001.md'],
            goal: 'Current roadmap work',
          },
        ],
      },
      null,
      2
    )
  )

  const output = run('./scripts/ralph/ralph-sprint.sh', ['next'], { cwd: repoDir })
  assert.equal(output.trim(), 'sprint-3')
})

test('ralph-archive clears local run artifacts after archiving a completed run', () => {
  const repoDir = initTempRepo()

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-test\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/.active-prd'),
    JSON.stringify(
      {
        mode: 'epic',
        epicId: 'EPIC-001',
        baseBranch: 'ralph/sprint/sprint-test',
        sourcePath: 'scripts/ralph/tasks/sprint-test/prd-epic-001.md',
        activatedAt: '2026-03-19T00:00:00-04:00',
      },
      null,
      2
    )
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/prd.json'),
    JSON.stringify(
      {
        project: 'tmp-ralph-test',
        branchName: 'ralph/sprint-test/epic-001',
        description: 'Archive test',
        userStories: [],
      },
      null,
      2
    )
  )
  writeFile(path.join(repoDir, 'scripts/ralph/progress.txt'), 'ARCHIVE ME\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.completion-state.json'), '{"status":"completed","completionSignal":true,"iteration":1,"branch":"ralph/sprint-test/epic-001","recordedAt":"2026-03-22T17:30:00-04:00"}\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-log-latest.txt'), 'ITER1 TRANSCRIPT\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-log-iter-1.txt'), 'ITER1 TRANSCRIPT\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-handoff-latest.json'), '{"status":"completed","summary":"done","completionSignal":true,"errors":[],"directionChanges":[],"verification":[],"filesChanged":[],"assumptions":[],"nextLoopAdvice":[]}\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-handoff-iter-1.json'), '{"status":"completed","summary":"done","completionSignal":true,"errors":[],"directionChanges":[],"verification":[],"filesChanged":[],"assumptions":[],"nextLoopAdvice":[]}\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.last-branch'), 'ralph/sprint-test/epic-001\n')
  fs.mkdirSync(path.join(repoDir, '.playwright-cli'), { recursive: true })

  run('./scripts/ralph/ralph-archive.sh', [], { cwd: repoDir })

  const archiveRoot = path.join(repoDir, 'scripts/ralph/tasks/archive/sprint-test')
  const archivedFolders = fs.readdirSync(archiveRoot)
  assert.equal(archivedFolders.length, 1)
  const archivedDir = path.join(archiveRoot, archivedFolders[0])
  assert.equal(fs.existsSync(path.join(archivedDir, 'prd.json')), true)
  assert.equal(fs.existsSync(path.join(archivedDir, 'progress.txt')), true)
  assert.equal(fs.existsSync(path.join(archivedDir, '.completion-state.json')), true)
  assert.equal(fs.existsSync(path.join(archivedDir, '.iteration-log-latest.txt')), true)
  assert.equal(fs.existsSync(path.join(archivedDir, '.iteration-log-iter-1.txt')), true)
  assert.equal(fs.existsSync(path.join(archivedDir, '.iteration-handoff-latest.json')), true)
  assert.equal(fs.existsSync(path.join(archivedDir, '.iteration-handoff-iter-1.json')), true)

  assert.equal(fs.existsSync(path.join(repoDir, 'scripts/ralph/progress.txt')), false)
  assert.equal(fs.existsSync(path.join(repoDir, 'scripts/ralph/.completion-state.json')), false)
  assert.equal(fs.existsSync(path.join(repoDir, 'scripts/ralph/.iteration-log-latest.txt')), false)
  assert.equal(fs.existsSync(path.join(repoDir, 'scripts/ralph/.iteration-log-iter-1.txt')), false)
  assert.equal(fs.existsSync(path.join(repoDir, 'scripts/ralph/.iteration-handoff-latest.json')), false)
  assert.equal(fs.existsSync(path.join(repoDir, 'scripts/ralph/.iteration-handoff-iter-1.json')), false)
  assert.equal(fs.existsSync(path.join(repoDir, '.playwright-cli')), false)
  assert.equal(fs.readFileSync(path.join(repoDir, 'scripts/ralph/prd.json'), 'utf8'), '')
})

test('ralph.sh resets stale progress when the previous branch was already archived', () => {
  const repoDir = initTempRepo()
  const env = { PATH: installCodexStub(repoDir) }

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-test\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/.active-prd'),
    JSON.stringify(
      {
        mode: 'epic',
        epicId: 'EPIC-001',
        baseBranch: 'ralph/sprint/sprint-test',
        sourcePath: 'scripts/ralph/tasks/sprint-test/prd-epic-001.md',
        activatedAt: '2026-03-19T00:00:00-04:00',
      },
      null,
      2
    )
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-test/epics.json'),
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        activeEpicId: 'EPIC-001',
        epics: [
          {
            id: 'EPIC-001',
            title: 'EPIC Test',
            priority: 1,
            status: 'active',
            dependsOn: [],
            prdPaths: ['scripts/ralph/tasks/sprint-test/prd-epic-001.md'],
            goal: 'Test goal',
          },
        ],
      },
      null,
      2
    )
  )
  writeFile(path.join(repoDir, 'scripts/ralph/tasks/sprint-test/prd-epic-001.md'), '# Test PRD\n')
  run('git', ['add', 'scripts/ralph/sprints/sprint-test/epics.json', 'scripts/ralph/tasks/sprint-test/prd-epic-001.md'], {
    cwd: repoDir,
  })
  run('git', ['commit', '-m', 'add sprint backlog fixture'], { cwd: repoDir })
  writeFile(
    path.join(repoDir, 'scripts/ralph/prd.json'),
    JSON.stringify(
      {
        project: 'tmp-ralph-test',
        branchName: 'ralph/sprint-test/epic-001',
        description: 'Loop test',
        userStories: [
          {
            id: 'US-001',
            title: 'In-progress story',
            description: 'In-progress story',
            acceptanceCriteria: ['Tests pass'],
            priority: 1,
            passes: false,
            notes: '',
          },
        ],
      },
      null,
      2
    )
  )
  writeFile(path.join(repoDir, 'scripts/ralph/progress.txt'), 'STALE LOOP PROGRESS\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.completion-state.json'), '{"status":"completed","completionSignal":true,"iteration":1,"branch":"ralph/sprint-test/epic-000","recordedAt":"2026-03-22T17:30:00-04:00"}\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-log-latest.txt'), 'STALE TRANSCRIPT\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-log-iter-1.txt'), 'STALE ITER TRANSCRIPT\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-handoff-latest.json'), '{"status":"no_change","summary":"stale","completionSignal":false,"errors":[],"directionChanges":[],"verification":[],"filesChanged":[],"assumptions":[],"nextLoopAdvice":[]}\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-handoff-iter-1.json'), '{"status":"no_change","summary":"stale","completionSignal":false,"errors":[],"directionChanges":[],"verification":[],"filesChanged":[],"assumptions":[],"nextLoopAdvice":[]}\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.last-branch'), 'ralph/sprint-test/epic-000\n')

  const archivedDir = path.join(
    repoDir,
    'scripts/ralph/tasks/archive/sprint-test/2026-03-19-sprint-test-epic-000'
  )
  writeFile(
    path.join(archivedDir, 'archive-manifest.txt'),
    [
      'archive_time=2026-03-19T00:00:00-04:00',
      'source_branch=ralph/sprint-test/epic-000',
      'source_iteration_transcripts=1',
      'archived_iteration_transcripts=1',
      'source_iteration_handoffs=1',
      'archived_iteration_handoffs=1',
      'source_playwright_cli_present=0',
      'archived_playwright_cli_present=0',
    ].join('\n') + '\n'
  )

  run('git', ['checkout', '-b', 'ralph/sprint/sprint-test'], { cwd: repoDir })

  let runError = null
  try {
    run('./scripts/ralph/ralph.sh', ['1'], { cwd: repoDir, env })
  } catch (error) {
    runError = error
  }

  assert.ok(runError)
  assert.equal(runError.status, 1)
  assert.match(runError.stdout + runError.stderr, /Ralph reached max iterations \(1\) without completing all tasks\./)

  const progress = fs.readFileSync(path.join(repoDir, 'scripts/ralph/progress.txt'), 'utf8')
  assert.match(progress, /# Ralph Progress Log/)
  assert.ok(!progress.includes('STALE LOOP PROGRESS'))
  assert.equal(fs.existsSync(path.join(repoDir, 'scripts/ralph/.completion-state.json')), false)
  assert.equal(run('git', ['branch', '--list', 'ralph/sprint/sprint-test'], { cwd: repoDir }).trim(), 'ralph/sprint/sprint-test')
  const latestHandoff = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/.iteration-handoff-latest.json'), 'utf8'))
  assert.equal(latestHandoff.completionSignal, false)
  assert.equal(latestHandoff.status, 'no_change')
})

test('ralph.sh cold-start primes the next epic before requiring a populated prd.json', () => {
  const repoDir = initTempRepo()
  const env = { PATH: installCodexStub(repoDir) }

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-test\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-test/epics.json'),
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        activeEpicId: null,
        epics: [
          {
            id: 'EPIC-001',
            title: 'EPIC Test',
            priority: 1,
            status: 'planned',
            dependsOn: [],
            prdPaths: ['scripts/ralph/tasks/sprint-test/prd-epic-001.md'],
            goal: 'Test goal',
          },
        ],
      },
      null,
      2
    )
  )
  writeFile(path.join(repoDir, 'scripts/ralph/tasks/sprint-test/prd-epic-001.md'), '# Test PRD\n')
  writeFile(path.join(repoDir, 'scripts/ralph/prd.json'), '')
  run('git', ['add', 'scripts/ralph/sprints/sprint-test/epics.json', 'scripts/ralph/tasks/sprint-test/prd-epic-001.md'], {
    cwd: repoDir,
  })
  run('git', ['commit', '-m', 'add sprint backlog fixture'], { cwd: repoDir })
  run('git', ['checkout', '-b', 'ralph/sprint/sprint-test'], { cwd: repoDir })

  let runError = null
  try {
    run('./scripts/ralph/ralph.sh', ['1'], { cwd: repoDir, env })
  } catch (error) {
    runError = error
  }

  assert.ok(runError)
  assert.equal(runError.status, 1)
  assert.match(runError.stdout, /Primed scripts\/ralph\/prd\.json with 1 remaining stories from EPIC-001\./)

  const primed = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/prd.json'), 'utf8'))
  assert.equal(primed.branchName, 'ralph/sprint-test/epic-001')
  assert.match(fs.readFileSync(path.join(repoDir, 'scripts/ralph/.active-prd'), 'utf8'), /"epicId": "EPIC-001"/)
})

test('completion transient matcher ignores generated prompt-context epic markdown', () => {
  const repoDir = initTempRepo()

  writeFile(path.join(repoDir, 'scripts/ralph/tasks/sprint-test/prd-epic-001-generated.md'), '# Generated PRD\n')

  const statusOutput = run('git', ['status', '--porcelain', '--untracked-files=all'], { cwd: repoDir })
  const filtered = execFileSync(
    'bash',
    [
      '-lc',
      [
        'printf "%s\\n" "$STATUS_OUTPUT" | awk \'{',
        'path = substr($0, 4);',
        'if (path ~ /^scripts\\/ralph\\/prd\\.json$/) next;',
        'if (path ~ /^scripts\\/ralph\\/progress\\.txt$/) next;',
        'if (path ~ /^scripts\\/ralph\\/\\.active-prd$/) next;',
        'if (path ~ /^scripts\\/ralph\\/\\.last-branch$/) next;',
        'if (path ~ /^scripts\\/ralph\\/\\.codex-last-message(\\-iter-[0-9]+|-prd-bootstrap)?\\.txt$/) next;',
        'if (path ~ /^scripts\\/ralph\\/tasks(\\/[^/]+)?\\/?$/) next;',
        'if (path ~ /^scripts\\/ralph\\/tasks\\/[^/]+\\/prd-epic-[^/]+\\.md$/) next;',
        'if (path ~ /^\\.playwright-cli(\\/|$)/) next;',
        'if (path ~ /^scripts\\/ralph\\/\\.playwright-cli(\\/|$)/) next;',
        'print',
        '}\'',
      ].join(' '),
    ],
    {
      cwd: repoDir,
      env: {
        ...process.env,
        STATUS_OUTPUT: statusOutput,
      },
      encoding: 'utf8',
      stdio: 'pipe',
    }
  ).trim()

  assert.equal(statusOutput.trim(), '?? scripts/ralph/tasks/sprint-test/prd-epic-001-generated.md')
  assert.equal(filtered, '')
})

test('ralph-prime and archive treat EPIC-R sprint branches as epic-mode runs', () => {
  const repoDir = initTempRepo()
  const env = { PATH: installCodexStub(repoDir) }

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-test\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-test/epics.json'),
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        activeEpicId: null,
        epics: [
          {
            id: 'EPIC-R1',
            title: 'EPIC R Test',
            priority: 1,
            status: 'planned',
            dependsOn: [],
            prdPaths: ['scripts/ralph/tasks/sprint-test/prd-epic-r1.md'],
            goal: 'Test goal',
          },
        ],
      },
      null,
      2
    )
  )
  writeFile(path.join(repoDir, 'scripts/ralph/tasks/sprint-test/prd-epic-r1.md'), '# Test PRD\n')
  run('git', ['add', 'scripts/ralph/sprints/sprint-test/epics.json', 'scripts/ralph/tasks/sprint-test/prd-epic-r1.md'], {
    cwd: repoDir,
  })
  run('git', ['commit', '-m', 'add sprint backlog fixture'], { cwd: repoDir })

  run('./scripts/ralph/ralph-prime.sh', ['--auto'], { cwd: repoDir, env })

  const primed = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/prd.json'), 'utf8'))
  assert.equal(primed.branchName, 'ralph/sprint-test/epic-r1')

  const activePrd = fs.readFileSync(path.join(repoDir, 'scripts/ralph/.active-prd'), 'utf8')
  assert.match(activePrd, /"mode": "epic"/)
  assert.match(activePrd, /"epicId": "EPIC-R1"/)

  writeFile(path.join(repoDir, 'scripts/ralph/.last-branch'), 'ralph/sprint-test/epic-r1\n')
  run(
    'bash',
    [
      '-lc',
      'git add -A && (git diff --cached --quiet || git commit -m "sync Ralph tracked state")',
    ],
    { cwd: repoDir }
  )

  run('./scripts/ralph/ralph-archive.sh', [], { cwd: repoDir })

  const archiveRoot = path.join(repoDir, 'scripts/ralph/tasks/archive/sprint-test')
  const archivedFolders = fs.readdirSync(archiveRoot)
  assert.equal(archivedFolders.length, 1)
  assert.match(archivedFolders[0], /sprint-test-epic-r1/)
})

test('ralph-prime auto-commit persists generated epic markdown when promptContext creates it', () => {
  const repoDir = initTempRepo()
  const env = { PATH: installCodexStub(repoDir) }

  writeFile(path.join(repoDir, 'scripts/ralph/.active-sprint'), 'sprint-test\n')
  writeFile(
    path.join(repoDir, 'scripts/ralph/sprints/sprint-test/epics.json'),
    JSON.stringify(
      {
        version: 1,
        project: 'tmp-ralph-test',
        activeEpicId: null,
        epics: [
          {
            id: 'EPIC-001',
            title: 'Generated EPIC Test',
            priority: 1,
            status: 'planned',
            dependsOn: [],
            prdPaths: ['scripts/ralph/tasks/sprint-test/prd-epic-001-generated-epic-test.md'],
            goal: 'Test goal',
            promptContext: 'Generate the PRD from prompt context.',
          },
        ],
      },
      null,
      2
    )
  )
  run('git', ['add', 'scripts/ralph/sprints/sprint-test/epics.json'], { cwd: repoDir })
  run('git', ['commit', '-m', 'add sprint backlog without generated prd'], { cwd: repoDir })

  run('./scripts/ralph/ralph-prime.sh', ['--auto'], { cwd: repoDir, env })

  const generatedPath = path.join(repoDir, 'scripts/ralph/tasks/sprint-test/prd-epic-001-generated-epic-test.md')
  assert.equal(fs.existsSync(generatedPath), true)
  assert.match(run('git', ['ls-files', '--', 'scripts/ralph/tasks/sprint-test/prd-epic-001-generated-epic-test.md'], { cwd: repoDir }), /prd-epic-001-generated-epic-test\.md/)

  const lastCommit = run('git', ['log', '-1', '--pretty=%s'], { cwd: repoDir }).trim()
  assert.equal(lastCommit, 'chore(ralph): prime EPIC-001 active for loop startup')
})

test('ralph-prd persists generated standalone markdown while keeping prd.json transient', () => {
  const repoDir = initTempRepo()
  const env = { PATH: installCodexStub(repoDir) }

  run('./scripts/ralph/ralph-prd.sh', ['--feature', 'Stub feature', '--no-questions'], { cwd: repoDir, env })

  const markdownPath = path.join(repoDir, 'scripts/ralph/tasks/prds/prd-stub-feature.md')
  assert.equal(fs.existsSync(markdownPath), true)
  assert.match(run('git', ['ls-files', '--', 'scripts/ralph/tasks/prds/prd-stub-feature.md'], { cwd: repoDir }), /prd-stub-feature\.md/)
  assert.equal(run('git', ['log', '-1', '--pretty=%s'], { cwd: repoDir }).trim(), 'chore(ralph): add standalone PRD spec')

  let trackedPrdJson = true
  try {
    run('git', ['ls-files', '--error-unmatch', 'scripts/ralph/prd.json'], { cwd: repoDir })
  } catch {
    trackedPrdJson = false
  }
  assert.equal(trackedPrdJson, false)
})

test('ralph.sh explicit-scope validator allows verification-only test expansion', () => {
  const repoDir = initTempRepo()
  const env = {
    PATH: installCodexStub(repoDir),
    RALPH_TEST_LOOP_MODE: 'scope-valid',
  }
  run('git', ['add', '-f', 'bin/codex'], { cwd: repoDir })
  run('git', ['commit', '-m', 'add codex stub fixture'], { cwd: repoDir })

  writeFile(path.join(repoDir, 'src/allowed.ts'), 'export const allowed = "baseline";\n')
  run('git', ['add', 'src/allowed.ts'], { cwd: repoDir })
  run('git', ['commit', '-m', 'add scoped source fixture'], { cwd: repoDir })

  writeFile(
    path.join(repoDir, 'scripts/ralph/tasks/prds/prd-scope-test.md'),
    '# Scope PRD\n\nKeep source changes limited to src/allowed.ts.\n'
  )
  run('git', ['add', 'scripts/ralph/tasks/prds/prd-scope-test.md'], { cwd: repoDir })
  run('git', ['commit', '-m', 'add standalone scope prd fixture'], { cwd: repoDir })
  writeFile(
    path.join(repoDir, 'scripts/ralph/.active-prd'),
    JSON.stringify(
      {
        mode: 'standalone',
        baseBranch: 'master',
        sourcePath: 'scripts/ralph/tasks/prds/prd-scope-test.md',
        activatedAt: '2026-03-22T17:30:00-04:00',
      },
      null,
      2
    )
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/prd.json'),
    JSON.stringify(
      {
        project: 'tmp-ralph-test',
        branchName: 'ralph/test/standalone',
        description: 'Keep source changes limited to src/allowed.ts.',
        scopePaths: ['src/allowed.ts'],
        userStories: [
          {
            id: 'US-001',
            title: 'Scoped valid story',
            description: 'Scoped valid story',
            scopePaths: ['src/allowed.ts'],
            acceptanceCriteria: ['Keep source changes limited to src/allowed.ts.', 'Tests pass'],
            priority: 1,
            passes: false,
            notes: '',
          },
        ],
      },
      null,
      2
    )
  )

  const output = run('./scripts/ralph/ralph.sh', ['1'], { cwd: repoDir, env })
  const lastCommitStat = run('git', ['show', '--stat', '--oneline', '-1'], { cwd: repoDir })
  assert.match(output, /Ralph completed all tasks!/)
  assert.match(lastCommitStat, /src\/allowed\.ts/)
  assert.match(lastCommitStat, /tests\/browser\.test\.mjs/)
  assert.equal(fs.existsSync(path.join(repoDir, 'tests/browser.test.mjs')), true)
})

test('ralph.sh explicit-scope validator blocks out-of-scope source edits', () => {
  const repoDir = initTempRepo()
  const env = {
    PATH: installCodexStub(repoDir),
    RALPH_TEST_LOOP_MODE: 'scope-invalid',
  }
  run('git', ['add', '-f', 'bin/codex'], { cwd: repoDir })
  run('git', ['commit', '-m', 'add codex stub fixture'], { cwd: repoDir })

  writeFile(path.join(repoDir, 'src/allowed.ts'), 'export const allowed = "baseline";\n')
  run('git', ['add', 'src/allowed.ts'], { cwd: repoDir })
  run('git', ['commit', '-m', 'add scoped source fixture'], { cwd: repoDir })

  writeFile(
    path.join(repoDir, 'scripts/ralph/tasks/prds/prd-scope-test.md'),
    '# Scope PRD\n\nKeep source changes limited to src/allowed.ts.\n'
  )
  run('git', ['add', 'scripts/ralph/tasks/prds/prd-scope-test.md'], { cwd: repoDir })
  run('git', ['commit', '-m', 'add standalone scope prd fixture'], { cwd: repoDir })
  writeFile(
    path.join(repoDir, 'scripts/ralph/.active-prd'),
    JSON.stringify(
      {
        mode: 'standalone',
        baseBranch: 'master',
        sourcePath: 'scripts/ralph/tasks/prds/prd-scope-test.md',
        activatedAt: '2026-03-22T17:30:00-04:00',
      },
      null,
      2
    )
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/prd.json'),
    JSON.stringify(
      {
        project: 'tmp-ralph-test',
        branchName: 'ralph/test/standalone',
        description: 'Keep source changes limited to src/allowed.ts.',
        scopePaths: ['src/allowed.ts'],
        userStories: [
          {
            id: 'US-001',
            title: 'Scoped invalid story',
            description: 'Scoped invalid story',
            scopePaths: ['src/allowed.ts'],
            acceptanceCriteria: ['Keep source changes limited to src/allowed.ts.', 'Tests pass'],
            priority: 1,
            passes: false,
            notes: '',
          },
        ],
      },
      null,
      2
    )
  )

  let runError = null
  try {
    run('./scripts/ralph/ralph.sh', ['1'], { cwd: repoDir, env })
  } catch (error) {
    runError = error
  }

  assert.ok(runError)
  assert.equal(runError.status, 1)
  assert.match(runError.stdout + runError.stderr, /outside explicit scoped implementation paths/)
  assert.match(runError.stdout + runError.stderr, /src\/disallowed\.ts/)
})

test('ralph.sh explicit-scope validator blocks uncommitted out-of-scope edits', () => {
  const repoDir = initTempRepo()
  const env = {
    PATH: installCodexStub(repoDir),
    RALPH_TEST_LOOP_MODE: 'scope-uncommitted',
  }

  writeFile(path.join(repoDir, 'src/allowed.ts'), 'export const allowed = "baseline";\n')
  run('git', ['add', 'src/allowed.ts'], { cwd: repoDir })
  run('git', ['commit', '-m', 'add scoped source fixture'], { cwd: repoDir })

  writeFile(
    path.join(repoDir, 'scripts/ralph/tasks/prds/prd-scope-test.md'),
    '# Scope PRD\n\nKeep source changes limited to src/allowed.ts.\n'
  )
  run('git', ['add', 'scripts/ralph/tasks/prds/prd-scope-test.md'], { cwd: repoDir })
  run('git', ['commit', '-m', 'add standalone scope prd fixture'], { cwd: repoDir })
  writeFile(
    path.join(repoDir, 'scripts/ralph/.active-prd'),
    JSON.stringify(
      {
        mode: 'standalone',
        baseBranch: 'master',
        sourcePath: 'scripts/ralph/tasks/prds/prd-scope-test.md',
        activatedAt: '2026-03-22T17:30:00-04:00',
      },
      null,
      2
    )
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/prd.json'),
    JSON.stringify(
      {
        project: 'tmp-ralph-test',
        branchName: 'ralph/test/standalone',
        description: 'Keep source changes limited to src/allowed.ts.',
        scopePaths: ['src/allowed.ts'],
        userStories: [
          {
            id: 'US-001',
            title: 'Scoped uncommitted invalid story',
            description: 'Scoped uncommitted invalid story',
            scopePaths: ['src/allowed.ts'],
            acceptanceCriteria: ['Keep source changes limited to src/allowed.ts.', 'Tests pass'],
            priority: 1,
            passes: false,
            notes: '',
          },
        ],
      },
      null,
      2
    )
  )

  let runError = null
  try {
    run('./scripts/ralph/ralph.sh', ['1'], { cwd: repoDir, env })
  } catch (error) {
    runError = error
  }

  assert.ok(runError)
  assert.equal(runError.status, 1)
  assert.match(runError.stdout + runError.stderr, /uncommitted files outside explicit scoped implementation paths/)
  assert.match(runError.stdout + runError.stderr, /src\/disallowed\.ts/)
})

test('ralph.sh structured scopePaths validator works without text scope hints', () => {
  const repoDir = initTempRepo()
  const env = {
    PATH: installCodexStub(repoDir),
    RALPH_TEST_LOOP_MODE: 'scope-valid',
  }
  run('git', ['add', '-f', 'bin/codex'], { cwd: repoDir })
  run('git', ['commit', '-m', 'add codex stub fixture'], { cwd: repoDir })

  writeFile(path.join(repoDir, 'src/allowed.ts'), 'export const allowed = "baseline";\n')
  run('git', ['add', 'src/allowed.ts'], { cwd: repoDir })
  run('git', ['commit', '-m', 'add structured scope fixture'], { cwd: repoDir })

  writeFile(
    path.join(repoDir, 'scripts/ralph/tasks/prds/prd-structured-scope.md'),
    '# Scope PRD\n\nUpdate the greeting implementation and matching test.\n'
  )
  run('git', ['add', 'scripts/ralph/tasks/prds/prd-structured-scope.md'], { cwd: repoDir })
  run('git', ['commit', '-m', 'add structured scope prd fixture'], { cwd: repoDir })
  writeFile(
    path.join(repoDir, 'scripts/ralph/.active-prd'),
    JSON.stringify(
      {
        mode: 'standalone',
        baseBranch: 'master',
        sourcePath: 'scripts/ralph/tasks/prds/prd-structured-scope.md',
        activatedAt: '2026-03-22T17:30:00-04:00',
      },
      null,
      2
    )
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/prd.json'),
    JSON.stringify(
      {
        project: 'tmp-ralph-test',
        branchName: 'ralph/test/standalone',
        description: 'Structured scope paths only.',
        scopePaths: ['src/allowed.ts'],
        userStories: [
          {
            id: 'US-001',
            title: 'Structured scope story',
            description: 'Structured scope story',
            scopePaths: ['src/allowed.ts'],
            acceptanceCriteria: ['Tests pass'],
            priority: 1,
            passes: false,
            notes: '',
          },
        ],
      },
      null,
      2
    )
  )

  const output = run('./scripts/ralph/ralph.sh', ['1'], { cwd: repoDir, env })
  assert.match(output, /Ralph completed all tasks!/)
  const lastCommitStat = run('git', ['show', '--stat', '--oneline', '-1'], { cwd: repoDir })
  assert.match(lastCommitStat, /src\/allowed\.ts/)
  assert.match(lastCommitStat, /tests\/browser\.test\.mjs/)
})

test('ralph.sh blocks helper-script edits unless explicitly scoped', () => {
  const repoDir = initTempRepo()
  const env = {
    PATH: installCodexStub(repoDir),
    RALPH_TEST_LOOP_MODE: 'scope-helper-invalid',
  }
  run('git', ['add', '-f', 'bin/codex'], { cwd: repoDir })
  run('git', ['commit', '-m', 'add codex stub fixture'], { cwd: repoDir })

  writeFile(path.join(repoDir, 'scripts/browser-check.mjs'), 'console.log("baseline");\n')
  run('git', ['add', 'scripts/browser-check.mjs'], { cwd: repoDir })
  run('git', ['commit', '-m', 'add helper fixture'], { cwd: repoDir })

  writeFile(
    path.join(repoDir, 'scripts/ralph/tasks/prds/prd-helper-scope.md'),
    '# Scope PRD\n\nUpdate UI greeting and matching test only.\n'
  )
  run('git', ['add', 'scripts/ralph/tasks/prds/prd-helper-scope.md'], { cwd: repoDir })
  run('git', ['commit', '-m', 'add helper scope prd fixture'], { cwd: repoDir })
  writeFile(
    path.join(repoDir, 'scripts/ralph/.active-prd'),
    JSON.stringify(
      {
        mode: 'standalone',
        baseBranch: 'master',
        sourcePath: 'scripts/ralph/tasks/prds/prd-helper-scope.md',
        activatedAt: '2026-03-22T17:30:00-04:00',
      },
      null,
      2
    )
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/prd.json'),
    JSON.stringify(
      {
        project: 'tmp-ralph-test',
        branchName: 'ralph/test/standalone',
        description: 'Do not touch helper scripts.',
        scopePaths: ['src/allowed.ts', 'tests/browser.test.mjs'],
        userStories: [
          {
            id: 'US-001',
            title: 'Helper scope block story',
            description: 'Helper scope block story',
            scopePaths: ['src/allowed.ts', 'tests/browser.test.mjs'],
            acceptanceCriteria: ['Tests pass'],
            priority: 1,
            passes: false,
            notes: '',
          },
        ],
      },
      null,
      2
    )
  )

  let runError = null
  try {
    run('./scripts/ralph/ralph.sh', ['1'], { cwd: repoDir, env })
  } catch (error) {
    runError = error
  }

  assert.ok(runError)
  assert.equal(runError.status, 1)
  assert.match(runError.stdout + runError.stderr, /helper\/config\/build files without explicit scope approval/)
  assert.match(runError.stdout + runError.stderr, /scripts\/browser-check\.mjs/)
})

test('ralph.sh synthesizes a completed handoff when completion evidence exists but no handoff is emitted', () => {
  const repoDir = initTempRepo()
  const env = {
    PATH: installCodexStub(repoDir),
    RALPH_TEST_LOOP_MODE: 'missing-handoff-complete',
  }

  writeFile(
    path.join(repoDir, 'scripts/ralph/.active-prd'),
    JSON.stringify(
      {
        mode: 'standalone',
        baseBranch: 'master',
        sourcePath: 'scripts/ralph/prd.json',
        activatedAt: '2026-03-22T17:30:00-04:00',
      },
      null,
      2
    )
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/prd.json'),
    JSON.stringify(
      {
        project: 'tmp-ralph-test',
        branchName: 'ralph/test/standalone',
        description: 'Completion synthesis test.',
        userStories: [
          {
            id: 'US-001',
            title: 'Synthesized completion story',
            description: 'Synthesized completion story',
            acceptanceCriteria: ['Tests pass'],
            priority: 1,
            passes: false,
            notes: '',
          },
        ],
      },
      null,
      2
    )
  )

  const output = run('./scripts/ralph/ralph.sh', ['1'], { cwd: repoDir, env })
  assert.match(output, /Ralph completed all tasks!/)
  const latestHandoff = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/.iteration-handoff-latest.json'), 'utf8'))
  assert.equal(latestHandoff.completionSignal, true)
  assert.equal(latestHandoff.status, 'completed')
  const completionState = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/.completion-state.json'), 'utf8'))
  assert.equal(completionState.completionSignal, true)
  assert.equal(completionState.status, 'completed')
})

test('ralph.sh finalizes completion without a model-written completion note when strict evidence is present', () => {
  const repoDir = initTempRepo()
  const env = {
    PATH: installCodexStub(repoDir),
    RALPH_TEST_LOOP_MODE: 'strict-complete-no-note',
  }

  writeFile(
    path.join(repoDir, 'scripts/ralph/.active-prd'),
    JSON.stringify(
      {
        mode: 'standalone',
        baseBranch: 'master',
        sourcePath: 'scripts/ralph/prd.json',
        activatedAt: '2026-03-22T17:30:00-04:00',
      },
      null,
      2
    )
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/prd.json'),
    JSON.stringify(
      {
        project: 'tmp-ralph-test',
        branchName: 'ralph/test/standalone',
        description: 'Wrapper-owned completion finalization test.',
        userStories: [
          {
            id: 'US-001',
            title: 'Strict completion story',
            description: 'Strict completion story',
            acceptanceCriteria: ['Tests pass'],
            priority: 1,
            passes: false,
            notes: '',
          },
        ],
      },
      null,
      2
    )
  )

  const output = run('./scripts/ralph/ralph.sh', ['1'], { cwd: repoDir, env })
  assert.match(output, /Ralph completed all tasks!/)
  const progress = fs.readFileSync(path.join(repoDir, 'scripts/ralph/progress.txt'), 'utf8')
  assert.match(progress, /## \[.*\] - Completion/)
  assert.match(progress, /Ralph finalized completion after strict validation/)
  const latestHandoff = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/.iteration-handoff-latest.json'), 'utf8'))
  assert.equal(latestHandoff.completionSignal, true)
  assert.equal(latestHandoff.status, 'completed')
  assert.match(latestHandoff.summary, /Completion finalized by Ralph/)
  const completionState = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/.completion-state.json'), 'utf8'))
  assert.equal(completionState.completionSignal, true)
  assert.equal(completionState.status, 'completed')
})

test('ralph.sh records a blocked handoff when the codex command fails', () => {
  const repoDir = initTempRepo()
  const env = {
    PATH: installCodexStub(repoDir),
    RALPH_TEST_LOOP_MODE: 'codex-fail',
  }

  writeFile(
    path.join(repoDir, 'scripts/ralph/.active-prd'),
    JSON.stringify(
      {
        mode: 'standalone',
        baseBranch: 'master',
        sourcePath: 'scripts/ralph/prd.json',
        activatedAt: '2026-03-22T17:30:00-04:00',
      },
      null,
      2
    )
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/prd.json'),
    JSON.stringify(
      {
        project: 'tmp-ralph-test',
        branchName: 'ralph/test/standalone',
        description: 'Codex failure test.',
        userStories: [
          {
            id: 'US-001',
            title: 'Codex failure story',
            description: 'Codex failure story',
            acceptanceCriteria: ['Tests pass'],
            priority: 1,
            passes: false,
            notes: '',
          },
        ],
      },
      null,
      2
    )
  )

  let runError = null
  try {
    run('./scripts/ralph/ralph.sh', ['1'], { cwd: repoDir, env })
  } catch (error) {
    runError = error
  }

  assert.ok(runError)
  assert.equal(runError.status, 1)
  const latestHandoff = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/.iteration-handoff-latest.json'), 'utf8'))
  assert.equal(latestHandoff.status, 'blocked')
  assert.equal(latestHandoff.completionSignal, false)
  assert.match(latestHandoff.errors[0], /Codex exited with status 17/)
})

test('ralph.sh falls back to a blocked handoff when the emitted handoff is invalid', () => {
  const repoDir = initTempRepo()
  const env = {
    PATH: installCodexStub(repoDir),
    RALPH_TEST_LOOP_MODE: 'invalid-handoff',
  }

  writeFile(
    path.join(repoDir, 'scripts/ralph/.active-prd'),
    JSON.stringify(
      {
        mode: 'standalone',
        baseBranch: 'master',
        sourcePath: 'scripts/ralph/prd.json',
        activatedAt: '2026-03-22T17:30:00-04:00',
      },
      null,
      2
    )
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/prd.json'),
    JSON.stringify(
      {
        project: 'tmp-ralph-test',
        branchName: 'ralph/test/standalone',
        description: 'Invalid handoff test.',
        userStories: [
          {
            id: 'US-001',
            title: 'Invalid handoff story',
            description: 'Invalid handoff story',
            acceptanceCriteria: ['Tests pass'],
            priority: 1,
            passes: false,
            notes: '',
          },
        ],
      },
      null,
      2
    )
  )

  let runError = null
  try {
    run('./scripts/ralph/ralph.sh', ['1'], { cwd: repoDir, env })
  } catch (error) {
    runError = error
  }

  assert.ok(runError)
  const latestHandoff = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/.iteration-handoff-latest.json'), 'utf8'))
  assert.equal(latestHandoff.status, 'blocked')
  assert.equal(latestHandoff.completionSignal, false)
  assert.match(latestHandoff.errors[0], /Invalid handoff schema emitted/)
})

test('ralph.sh extracts the last handoff block from the transcript', () => {
  const repoDir = initTempRepo()
  const env = {
    PATH: installCodexStub(repoDir),
    RALPH_TEST_LOOP_MODE: 'multi-handoff',
  }

  writeFile(
    path.join(repoDir, 'scripts/ralph/.active-prd'),
    JSON.stringify(
      {
        mode: 'standalone',
        baseBranch: 'master',
        sourcePath: 'scripts/ralph/prd.json',
        activatedAt: '2026-03-22T17:30:00-04:00',
      },
      null,
      2
    )
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/prd.json'),
    JSON.stringify(
      {
        project: 'tmp-ralph-test',
        branchName: 'ralph/test/standalone',
        description: 'Last handoff wins test.',
        userStories: [
          {
            id: 'US-001',
            title: 'Last handoff story',
            description: 'Last handoff story',
            acceptanceCriteria: ['Tests pass'],
            priority: 1,
            passes: false,
            notes: '',
          },
        ],
      },
      null,
      2
    )
  )

  const output = run('./scripts/ralph/ralph.sh', ['1'], { cwd: repoDir, env })
  assert.match(output, /Ralph completed all tasks!/)
  const latestHandoff = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/.iteration-handoff-latest.json'), 'utf8'))
  assert.equal(latestHandoff.story.id, 'US-001')
  assert.equal(latestHandoff.status, 'completed')
  assert.equal(latestHandoff.completionSignal, true)
})

test('ralph.sh preserves the model story when completion fallback follows an invalid handoff schema', () => {
  const repoDir = initTempRepo()
  const env = {
    PATH: installCodexStub(repoDir),
    RALPH_TEST_LOOP_MODE: 'invalid-completion-schema',
  }

  writeFile(
    path.join(repoDir, 'scripts/ralph/.active-prd'),
    JSON.stringify(
      {
        mode: 'standalone',
        baseBranch: 'master',
        sourcePath: 'scripts/ralph/prd.json',
        activatedAt: '2026-03-22T17:30:00-04:00',
      },
      null,
      2
    )
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/prd.json'),
    JSON.stringify(
      {
        project: 'tmp-ralph-test',
        branchName: 'ralph/test/standalone',
        description: 'Fallback story preservation test.',
        userStories: [
          {
            id: 'US-001',
            title: 'First story',
            description: 'First story',
            acceptanceCriteria: ['Tests pass'],
            priority: 1,
            passes: false,
            notes: '',
          },
          {
            id: 'US-002',
            title: 'Second story',
            description: 'Second story',
            acceptanceCriteria: ['Tests pass'],
            priority: 2,
            passes: false,
            notes: '',
          },
        ],
      },
      null,
      2
    )
  )

  const output = run('./scripts/ralph/ralph.sh', ['1'], { cwd: repoDir, env })
  assert.match(output, /Ralph completed all tasks!/)
  const latestHandoff = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/.iteration-handoff-latest.json'), 'utf8'))
  assert.equal(latestHandoff.story.id, 'US-002')
  assert.equal(latestHandoff.story.title, 'Second story')
  assert.equal(latestHandoff.status, 'completed')
  assert.equal(latestHandoff.completionSignal, true)
})

test('ralph.sh accepts completion handoffs with three verification entries', () => {
  const repoDir = initTempRepo()
  const env = {
    PATH: installCodexStub(repoDir),
    RALPH_TEST_LOOP_MODE: 'three-verification-completion',
  }

  writeFile(
    path.join(repoDir, 'scripts/ralph/.active-prd'),
    JSON.stringify(
      {
        mode: 'standalone',
        baseBranch: 'master',
        sourcePath: 'scripts/ralph/prd.json',
        activatedAt: '2026-03-22T17:30:00-04:00',
      },
      null,
      2
    )
  )
  writeFile(
    path.join(repoDir, 'scripts/ralph/prd.json'),
    JSON.stringify(
      {
        project: 'tmp-ralph-test',
        branchName: 'ralph/test/standalone',
        description: 'Three verification entries test.',
        userStories: [
          {
            id: 'US-001',
            title: 'First story',
            description: 'First story',
            acceptanceCriteria: ['Tests pass'],
            priority: 1,
            passes: false,
            notes: '',
          },
          {
            id: 'US-002',
            title: 'Second story',
            description: 'Second story',
            acceptanceCriteria: ['Tests pass'],
            priority: 2,
            passes: false,
            notes: '',
          },
        ],
      },
      null,
      2
    )
  )

  const output = run('./scripts/ralph/ralph.sh', ['1'], { cwd: repoDir, env })
  assert.match(output, /Ralph completed all tasks!/)
  const latestHandoff = JSON.parse(fs.readFileSync(path.join(repoDir, 'scripts/ralph/.iteration-handoff-latest.json'), 'utf8'))
  assert.equal(latestHandoff.story.id, 'US-002')
  assert.equal(latestHandoff.story.title, 'Second story')
  assert.doesNotMatch(latestHandoff.summary, /invalid handoff schema/i)
  assert.equal(latestHandoff.status, 'completed')
  assert.equal(latestHandoff.completionSignal, true)
})

test('ralph-archive rejects unpaired transcript and handoff artifacts', () => {
  const repoDir = initTempRepo()

  writeFile(path.join(repoDir, 'scripts/ralph/prd.json'), '{}\n')
  writeFile(path.join(repoDir, 'scripts/ralph/progress.txt'), 'ARCHIVE ME\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-log-iter-1.txt'), 'ITER1 TRANSCRIPT\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-handoff-iter-2.json'), '{"status":"no_change","summary":"mismatch","completionSignal":false,"errors":[],"directionChanges":[],"verification":[],"filesChanged":[],"assumptions":[],"nextLoopAdvice":[]}\n')

  let archiveError = null
  try {
    run('./scripts/ralph/ralph-archive.sh', [], { cwd: repoDir })
  } catch (error) {
    archiveError = error
  }

  assert.ok(archiveError)
  assert.match(archiveError.stderr, /iteration transcript\/handoff files are not paired/)
})

test('ralph-archive rejects stale latest artifact pointers', () => {
  const repoDir = initTempRepo()

  writeFile(path.join(repoDir, 'scripts/ralph/prd.json'), '{}\n')
  writeFile(path.join(repoDir, 'scripts/ralph/progress.txt'), 'ARCHIVE ME\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-log-iter-1.txt'), 'ITER1 TRANSCRIPT\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-log-iter-2.txt'), 'ITER2 TRANSCRIPT\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-log-latest.txt'), 'ITER1 TRANSCRIPT\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-handoff-iter-1.json'), '{"status":"no_change","summary":"iter1","completionSignal":false,"errors":[],"directionChanges":[],"verification":[],"filesChanged":[],"assumptions":[],"nextLoopAdvice":[]}\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-handoff-iter-2.json'), '{"status":"no_change","summary":"iter2","completionSignal":false,"errors":[],"directionChanges":[],"verification":[],"filesChanged":[],"assumptions":[],"nextLoopAdvice":[]}\n')
  writeFile(path.join(repoDir, 'scripts/ralph/.iteration-handoff-latest.json'), '{"status":"no_change","summary":"iter1","completionSignal":false,"errors":[],"directionChanges":[],"verification":[],"filesChanged":[],"assumptions":[],"nextLoopAdvice":[]}\n')

  let archiveError = null
  try {
    run('./scripts/ralph/ralph-archive.sh', [], { cwd: repoDir })
  } catch (error) {
    archiveError = error
  }

  assert.ok(archiveError)
  assert.match(archiveError.stderr, /latest transcript file does not match the highest iteration transcript|latest handoff file does not match the highest iteration handoff/)
})
