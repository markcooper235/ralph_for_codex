import { requireGitPort } from '../ports/git.mjs'

export async function ensureSprintBranch({ git, sprintBranch, baseBranch }) {
  requireGitPort(git)
  if (!sprintBranch || !baseBranch) return { action: 'skipped', branch: sprintBranch }
  if (await git.hasBranch(sprintBranch)) return { action: 'existing', branch: sprintBranch }
  await git.createBranch(sprintBranch, baseBranch)
  await git.setBranchParent(sprintBranch, baseBranch)
  return { action: 'created', branch: sprintBranch, parent: baseBranch }
}
