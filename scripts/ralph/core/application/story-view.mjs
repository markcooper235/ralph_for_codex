import { readBacklog } from '../repositories/backlog-repository.mjs'
import { readStory } from '../repositories/story-repository.mjs'

export async function listStories(backlogPath) {
  const backlog = await readBacklog(backlogPath)
  return {
    sprint: backlog.sprint ?? '',
    activeStoryId: backlog.activeStoryId ?? null,
    stories: backlog.stories
      .slice()
      .sort((left, right) => {
        const priority = (left.priority ?? null) === (right.priority ?? null)
          ? 0
          : left.priority == null ? 1 : right.priority == null ? -1 : left.priority - right.priority
        return priority || String(left.id).localeCompare(String(right.id))
      })
  }
}

export async function getStory(backlogPath, storyId) {
  const backlog = await readBacklog(backlogPath)
  const metadata = backlog.stories.find((story) => String(story.id) === String(storyId))
  if (!metadata) throw new Error(`Story ${storyId} not found.`)
  if (!metadata.story_path) throw new Error(`Story ${storyId} has no story_path.`)
  return readStory(metadata.story_path)
}

export async function getStoryTasks(backlogPath, storyId) {
  const story = await getStory(backlogPath, storyId)
  return { storyId, tasks: story.tasks }
}
