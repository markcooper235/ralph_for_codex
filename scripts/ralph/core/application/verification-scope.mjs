import { execFile } from 'node:child_process'
import { readFile } from 'node:fs/promises'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)

async function git(workspaceRoot, args) {
  try { return (await execFileAsync('git', ['-C', workspaceRoot, ...args], { encoding: 'utf8' })).stdout } catch { return '' }
}

function unique(values) { return [...new Set(values.filter(Boolean))].sort() }

export async function collectChangedFiles(workspaceRoot) {
  const [tracked, untracked] = await Promise.all([
    git(workspaceRoot, ['diff', '--name-only', '--diff-filter=ACMRTUXB', 'HEAD']),
    git(workspaceRoot, ['ls-files', '--others', '--exclude-standard']),
  ])
  return unique(`${tracked}\n${untracked}`.split(/\r?\n/))
}

export async function collectStoryScope(storyPath, taskId = '') {
  const story = JSON.parse(await readFile(storyPath, 'utf8'))
  if (taskId) return unique(story.tasks.find((task) => task.id === taskId)?.scope ?? [])
  return unique([
    ...(story.story_handoff?.files_touched ?? []),
    ...story.tasks.flatMap((task) => task.handoff?.changed_files ?? task.scope ?? []),
  ])
}

export async function collectSprintScope(workspaceRoot, sprintBranch, mergeTarget = '') {
  const target = mergeTarget || (await git(workspaceRoot, ['for-each-ref', '--format=%(upstream:short)', `refs/heads/${sprintBranch}`])).trim() || ((await git(workspaceRoot, ['show-ref', '--verify', '--quiet', 'refs/heads/master'])) ? 'master' : 'main')
  const base = (await git(workspaceRoot, ['merge-base', target, sprintBranch])).trim()
  return unique((await git(workspaceRoot, ['diff', '--name-only', '--diff-filter=ACMRTUXB', `${base}..${sprintBranch}`])).split(/\r?\n/))
}
