import { readStory } from '../repositories/story-repository.mjs'
import { runCheck } from './check-runner.mjs'

export async function validateStoryContainer(storyPath, expectedStoryId, expectedSprint) {
  const story = await readStory(storyPath)
  if (story.storyId !== expectedStoryId) throw new Error(`Imported story.json storyId must be ${expectedStoryId}`)
  if (story.sprint !== expectedSprint) throw new Error(`Imported story.json sprint must be ${expectedSprint}`)
  if (!Array.isArray(story.tasks) || story.tasks.length === 0) throw new Error('Imported story.json must contain tasks[]')
  for (const task of story.tasks) {
    if (!Array.isArray(task.checks) || task.checks.length === 0) throw new Error('Imported story.json has task(s) without checks')
    for (const check of task.checks) {
      const result = await runCheck(`bash -n <<< ${JSON.stringify(check)}`, process.cwd())
      if (!result.passed) throw new Error(`Imported story.json contains shell-invalid checks: ${check}`)
    }
  }
  return story
}
