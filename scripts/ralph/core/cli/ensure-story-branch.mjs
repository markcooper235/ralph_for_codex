import { ensureStoryBranch } from '../application/ensure-story-branch.mjs'
import { createGitProcessAdapter } from '../adapters/git-process.mjs'

const [workspaceRoot, storyBranch = '', sprintBranch = ''] = process.argv.slice(2)

if (!workspaceRoot) {
  console.error('Usage: ensure-story-branch.mjs <workspace> <story-branch> [sprint-branch]')
  process.exitCode = 2
} else {
  try {
    const result = await ensureStoryBranch({
      git: createGitProcessAdapter({ cwd: workspaceRoot }),
      storyBranch,
      sprintBranch,
    })
    if (result?.action === 'checkout') {
      process.stdout.write(`Checked out story branch: ${result.branch}\n`)
    } else if (result?.parent) {
      process.stdout.write(`Created story branch: ${result.branch} (from ${result.parent})\n`)
    } else if (result) {
      process.stdout.write(`Created story branch: ${result.branch} (from current HEAD)\n`)
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
