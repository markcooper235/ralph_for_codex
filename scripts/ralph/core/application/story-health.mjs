import { access } from 'node:fs/promises'
import { runCheck } from './check-runner.mjs'
import { readStory } from '../repositories/story-repository.mjs'

async function exists(path) { try { await access(path); return true } catch { return false } }

export async function analyzeStoryHealth(storyPath, storyId, backlogStatus = '') {
  const issues = []
  const messages = [`[${storyId}] ${backlogStatus}`]
  if (!(await exists(storyPath))) return { healthy: false, messages: [...messages, `  [MISSING] story.json not found: ${storyPath}`] }
  const story = await readStory(storyPath)
  if (story.migration?.tasks_recovered === false) {
    if (['done', 'abandoned'].includes(backlogStatus)) messages.push('  [INFO] Historical migration placeholder retained (task-level data was not recoverable)')
    else { messages.push('  [MIGRATION] task-level data was not recovered; regenerate this story before execution'); issues.push('migration') }
  }
  const specifyDir = `${storyPath.substring(0, storyPath.lastIndexOf('/'))}/.specify`
  if (await exists(specifyDir)) {
    for (const artifact of ['spec.md', 'plan.md', 'tasks.md']) {
      if (!(await exists(`${specifyDir}/${artifact}`))) { messages.push(`  [SPECKIT] Missing artifact: ${artifact} (partial run — re-run specify with --force)`); issues.push(artifact) }
    }
  }
  if (story.tasks.length === 0) { messages.push('  [WARN] No tasks defined'); issues.push('tasks') }
  const ids = new Set()
  const checkSets = new Map()
  for (const task of story.tasks) {
    if (ids.has(task.id)) { messages.push(`  [DUP] task id repeated: ${task.id}`); issues.push('duplicate-task') }
    ids.add(task.id)
    if (!Array.isArray(task.checks) || task.checks.length === 0) { messages.push(`  [WARN] ${task.id}: no acceptance checks`); issues.push('checks') }
    if (!task.context) { messages.push(`  [WARN] ${task.id}: empty context`); issues.push('context') }
    for (const dep of task.depends_on ?? []) if (!ids.has(dep) && !story.tasks.some((candidate) => candidate.id === dep)) { messages.push(`  [DEAD] ${task.id}: depends_on '${dep}' not found in story`); issues.push('dependency') }
    const seenChecks = new Set()
    for (const check of task.checks ?? []) {
      if (seenChecks.has(check)) { messages.push(`  [DUP]  ${task.id}: check listed more than once: ${check}`); issues.push('duplicate-check') }
      seenChecks.add(check)
      const syntax = await runCheck(`bash -n -c ${JSON.stringify(check)}`, process.cwd())
      if (!syntax.passed) { messages.push(`  [SYNTAX] ${task.id}: syntax error: ${check}`); issues.push('syntax') }
    }
    const key = [...(task.checks ?? [])].sort().join('\u0000')
    if (checkSets.has(key)) {
      const prior = checkSets.get(key)
      if ((prior.title ?? '').toLowerCase().includes((task.title ?? '').toLowerCase()) || (task.title ?? '').toLowerCase().includes((prior.title ?? '').toLowerCase())) {
        messages.push(`  [DUP]  Tasks share identical check sets and similar titles: ${prior.id}, ${task.id}`); issues.push('duplicate-task-set')
      }
    } else checkSets.set(key, task)
    if ((task.depends_on ?? []).includes(task.id)) { messages.push(`  [CYCLE] ${task.id}: depends on itself`); issues.push('cycle') }
  }
  if (issues.length === 0) messages.push('  OK')
  return { healthy: issues.length === 0, messages }
}
