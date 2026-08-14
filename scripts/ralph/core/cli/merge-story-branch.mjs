import { createGitProcessAdapter } from '../adapters/git-process.mjs'
import { mergeStoryBranch } from '../application/merge-story-branch.mjs'

const [workspaceRoot, storyBranch, mergeTarget, storyId, storyTitle = ''] = process.argv.slice(2)

if (!workspaceRoot || !storyBranch || !mergeTarget || !storyId) {
  console.error('Usage: merge-story-branch.mjs <workspace-root> <story-branch> <merge-target> <story-id> [story-title]')
  process.exitCode = 2
} else {
  try {
    const result = await mergeStoryBranch({
      git: createGitProcessAdapter({ cwd: workspaceRoot }),
      storyBranch,
      mergeTarget,
      storyId,
      storyTitle,
    })
    process.stdout.write(`${result.status}\n`)
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
