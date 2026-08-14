import { requireGitPort } from '../ports/git.mjs'

export async function mergeStoryBranch({ git, storyBranch, mergeTarget, storyId, storyTitle }) {
  requireGitPort(git)
  const workflowMethods = ['stageAll', 'hasCachedChanges', 'commit', 'mergeNoFastForward', 'deleteBranch']
  if (workflowMethods.some((method) => typeof git[method] !== 'function')) {
    throw new TypeError(`Git port must implement: ${workflowMethods.join(', ')}`)
  }
  if (!storyBranch || !mergeTarget) return { status: 'skipped', reason: 'missing-branch' }
  if (!(await git.hasBranch(storyBranch))) return { status: 'skipped', reason: 'story-branch-missing' }
  if (!(await git.hasBranch(mergeTarget))) return { status: 'skipped', reason: 'merge-target-missing' }

  await git.stageAll()
  if (await git.hasCachedChanges()) {
    await git.commit(`chore(ralph): checkpoint verified ${storyId} implementation`)
  }
  await git.checkout(mergeTarget)
  await git.mergeNoFastForward(storyBranch, `merge: ${storyId} — ${storyTitle}`)
  await git.deleteBranch(storyBranch)
  return { status: 'merged', storyBranch, mergeTarget }
}
