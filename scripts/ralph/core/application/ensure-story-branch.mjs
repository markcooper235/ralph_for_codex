import { requireGitPort } from '../ports/git.mjs'

/**
 * Ensure the story branch exists and is checked out.
 *
 * @param {{ git: import('../ports/git.mjs').GitPort, storyBranch?: string, sprintBranch?: string }} options
 * @returns {Promise<{action: string, branch: string, parent?: string} | null>}
 */
export async function ensureStoryBranch({ git, storyBranch = '', sprintBranch = '' }) {
  requireGitPort(git)
  if (!storyBranch) return null

  if (await git.hasBranch(storyBranch)) {
    await git.checkout(storyBranch)
    if (sprintBranch && !(await git.branchParent(storyBranch))) {
      await git.setBranchParent(storyBranch, sprintBranch)
      return { action: 'checkout', branch: storyBranch, parent: sprintBranch }
    }
    return { action: 'checkout', branch: storyBranch }
  }

  if (sprintBranch && await git.hasBranch(sprintBranch)) {
    await git.createBranch(storyBranch, sprintBranch)
    await git.setBranchParent(storyBranch, sprintBranch)
    return { action: 'create', branch: storyBranch, parent: sprintBranch }
  }

  await git.createBranch(storyBranch)
  return { action: 'create', branch: storyBranch }
}
