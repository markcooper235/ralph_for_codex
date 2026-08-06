import { readFile } from 'node:fs/promises'
import { readStory } from '../repositories/story-repository.mjs'
import { pendingTaskChecks } from './execution-plan.mjs'

export async function buildExecutionContext(storyPath, dependencyPath, targetTaskId = '') {
  const story = await readStory(storyPath)
  const dependencyHandoff = JSON.parse(await readFile(dependencyPath, 'utf8'))
  const pending = pendingTaskChecks(story, targetTaskId)
  return {
    storyId: story.storyId,
    title: story.title,
    goal: story.goal ?? story.description ?? '',
    scope: story.spec?.scope ?? '',
    preserved_invariants: story.spec?.preserved_invariants ?? [],
    dependency_handoff: dependencyHandoff,
    pending_task_ids: pending.map((task) => task.id),
    target_task_id: targetTaskId || null,
  }
}
