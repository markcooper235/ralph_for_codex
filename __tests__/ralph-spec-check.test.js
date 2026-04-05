const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { execFileSync, spawnSync } = require('node:child_process')

const REPO_ROOT = path.resolve(__dirname, '..')
const SPEC_CHECK = path.join(REPO_ROOT, 'ralph-spec-check.sh')

function writeTempSpec(contents) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ralph-spec-check-'))
  const filePath = path.join(tempDir, 'spec.md')
  fs.writeFileSync(filePath, contents)
  return filePath
}

function strongSpec() {
  return `# PRD - Strong Spec

## Scope
- Tighten Ralph planning quality gates for execution-ready specs.

## Out of Scope
- Changing Ralph loop runtime behavior.

## Execution Model
- Start with a first slice that hardens the checker before prompt changes so sequencing stays explicit.
- Keep support scope limited to the checker, prompt builder, and the tests needed to verify those seams.
- Verify with focused script tests first, then broader Ralph workflow coverage once the checker and prompts settle.

## First Slice Expectations
- exact source: ralph-spec-check.sh
- destination: scripts/ralph/prd.json quality gate behavior
- entrypoint: ./ralph-prd.sh
- caller workflow: generate markdown, validate it, strengthen only if needed, then convert to JSON

## Allowed Supporting Files
- ralph-prd.sh
- __tests__/ralph-spec-check.test.js
- package.json and jest config files if the verification command needs them

## Preserved Invariants
- Existing Ralph workflow sequencing must remain stable and unchanged.
- Strengthening must remain a fallback path rather than the canonical planning pass.

## User Stories
### Story 1: Harden the checker
Acceptance Criteria
- Must reject specs whose acceptance criteria omit explicit proof obligations such as Typecheck passes or Unit tests pass.
- Must reject specs that leave first-slice source or workflow details vague.
- Must Typecheck passes.
- Must Lint passes.
- Must Unit tests pass.

## Refinement Checkpoints
- Checkpoint A: lock the stricter checker rubric before editing prompt text.

## Definition of Done
- Ralph planning produces stronger loop-ready specs with concrete proof expectations.
`
}

test('ralph-spec-check.sh passes a spec with explicit execution and proof detail', () => {
  const filePath = writeTempSpec(strongSpec())
  const output = execFileSync(SPEC_CHECK, [filePath], { encoding: 'utf8' })
  assert.match(output, /PASS:/)
})

test('ralph-spec-check.sh fails specs that omit explicit proof obligations', () => {
  const filePath = writeTempSpec(
    strongSpec().replace(
      `Acceptance Criteria
- Must reject specs whose acceptance criteria omit explicit proof obligations such as Typecheck passes or Unit tests pass.
- Must reject specs that leave first-slice source or workflow details vague.
- Must Typecheck passes.
- Must Lint passes.
- Must Unit tests pass.`,
      `Acceptance Criteria
- Must preserve explicit source ownership in the first slice.
- Must keep support scope bounded to the checker and prompt builder.
- Must leave the workflow ready for JSON handoff.`
    )
  )
  const result = spawnSync(SPEC_CHECK, [filePath], { encoding: 'utf8' })
  const combinedOutput = `${result.stdout}${result.stderr}`
  assert.equal(result.status, 1)
  assert.match(combinedOutput, /Each story needs at least one explicit proof obligation/)
})

test('ralph-spec-check.sh fails specs with vague acceptance language', () => {
  const filePath = writeTempSpec(
    strongSpec().replace(
      '- Must reject specs that leave first-slice source or workflow details vague.',
      '- Must reject vague specs as needed and/or if applicable.'
    )
  )
  const result = spawnSync(SPEC_CHECK, [filePath], { encoding: 'utf8' })
  const combinedOutput = `${result.stdout}${result.stderr}`
  assert.equal(result.status, 1)
  assert.match(combinedOutput, /Acceptance criteria still contain vague execution language/)
})
