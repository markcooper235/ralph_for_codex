import { createGitProcessAdapter } from '../adapters/git-process.mjs'
import { ensureSprintBranch } from '../application/ensure-sprint-branch.mjs'

const [workspaceRoot, sprintBranch, baseBranch] = process.argv.slice(2)

if (!workspaceRoot || !sprintBranch || !baseBranch) {
  console.error('Usage: ensure-sprint-branch.mjs <workspace-root> <sprint-branch> <base-branch>')
  process.exitCode = 2
} else {
  try {
    const result = await ensureSprintBranch({
      git: createGitProcessAdapter({ cwd: workspaceRoot }),
      sprintBranch,
      baseBranch,
    })
    if (result.action === 'created') {
      process.stdout.write(`Created sprint branch: ${result.branch} (from ${result.parent})\n`)
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
