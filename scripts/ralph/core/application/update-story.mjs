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

export async function updateTaskField(storyPath, taskId, field, value) {
  const story = await readStory(storyPath)
  const updatedStory = {
    ...story,
    tasks: story.tasks.map((task) => (
      String(task.id) === String(taskId) ? { ...task, [field]: value } : task
    )),
  }
  await writeStoryAtomic(storyPath, updatedStory)
}

export async function updateStoryField(storyPath, field, value) {
  const story = await readStory(storyPath)
  await writeStoryAtomic(storyPath, { ...story, [field]: value })
}
