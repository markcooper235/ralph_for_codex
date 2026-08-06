import { readStory } from '../repositories/story-repository.mjs'
import { storyIsComplete, verificationDecision } from '../domain/task.mjs'

export async function getTaskVerificationDecision(storyPath, taskId, failureSeen = false) {
  const story = await readStory(storyPath)
  return verificationDecision(story, taskId, failureSeen)
}

export async function isStoryComplete(storyPath) {
  return storyIsComplete(await readStory(storyPath))
}
