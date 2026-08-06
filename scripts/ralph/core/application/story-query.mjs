import { readStory } from '../repositories/story-repository.mjs'

export async function getTaskIds(storyPath, targetTaskId = '') {
  const story = await readStory(storyPath)
  return story.tasks
    .filter((task) => task.passes !== true)
    .filter((task) => !targetTaskId || String(task.id) === String(targetTaskId))
    .map((task) => task.id)
}

export async function getTaskChecks(storyPath, taskId) {
  const story = await readStory(storyPath)
  return story.tasks.find((task) => String(task.id) === String(taskId))?.checks ?? []
}

export async function getTaskStatus(storyPath, taskId) {
  const story = await readStory(storyPath)
  return story.tasks.find((task) => String(task.id) === String(taskId))?.status ?? 'pending'
}

export async function getTaskPasses(storyPath, taskId) {
  const story = await readStory(storyPath)
  return story.tasks.find((task) => String(task.id) === String(taskId))?.passes === true
}

export async function getStoryMetadata(storyPath) {
  const story = await readStory(storyPath)
  return {
    storyId: story.storyId ?? '',
    title: story.title ?? '',
    branchName: story.branchName ?? '',
    agent: story.agent ?? '',
  }
}
