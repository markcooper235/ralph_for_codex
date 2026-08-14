import { createGitProcessAdapter } from '../adapters/git-process.mjs'
import { getBranchParent } from '../application/branch-parent.mjs'

const [command, workspaceRoot, branchName] = process.argv.slice(2)

if (command !== 'parent' || !workspaceRoot || !branchName) {
  console.error('Usage: git-branch.mjs parent <workspace-root> <branch>')
  process.exitCode = 2
} else {
  try {
    process.stdout.write(`${await getBranchParent({
      git: createGitProcessAdapter({ cwd: workspaceRoot }),
      branchName,
    })}\n`)
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
