import { applyTaskResult } from '../domain/task.mjs'
import { readStory, writeStoryAtomic } from '../repositories/story-repository.mjs'

export async function updateTaskResult(storyPath, taskId, passed) {
  const story = await readStory(storyPath)
  await writeStoryAtomic(storyPath, applyTaskResult(story, taskId, passed))
}

export async function completeStory(storyPath) {
  const story = await readStory(storyPath)
  await writeStoryAtomic(storyPath, { ...story, status: 'done', passes: true })
}
