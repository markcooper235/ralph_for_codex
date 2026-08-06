import { readStory } from '../repositories/story-repository.mjs'

export function pendingTaskChecks(story, targetTaskId = '') {
  return (story.tasks ?? [])
    .filter((task) => task.passes !== true)
    .filter((task) => !targetTaskId || String(task.id) === String(targetTaskId))
    .map((task) => ({
      id: task.id,
      title: task.title,
      depends_on: task.depends_on ?? [],
      checks: task.checks ?? [],
    }))
}

export async function buildExecutionChecks(storyPath, targetTaskId = '') {
  return pendingTaskChecks(await readStory(storyPath), targetTaskId)
}
