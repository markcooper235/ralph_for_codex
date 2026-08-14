import { requireGitPort } from '../ports/git.mjs'

export async function getBranchParent({ git, branchName }) {
  requireGitPort(git)
  if (!branchName) return ''
  return git.branchParent(branchName)
}
