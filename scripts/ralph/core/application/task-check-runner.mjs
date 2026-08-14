import { readStory } from '../repositories/story-repository.mjs'
import { runCheck } from './check-runner.mjs'

export async function runTaskChecks(storyPath, workspaceRoot, taskId, timeoutMs = 0) {
  const story = await readStory(storyPath)
  const task = story.tasks.find((candidate) => String(candidate.id) === String(taskId))
  if (!task) throw new Error(`Task not found: ${taskId}`)
  const checks = []
  for (const [index, check] of (task.checks ?? []).entries()) {
    checks.push({ checkIndex: index + 1, check, ...(await runCheck(check, workspaceRoot, { timeoutMs })) })
  }
  return { taskId, passed: checks.every((result) => result.passed), checks }
}
