import { readBacklog, writeBacklogAtomic } from '../repositories/backlog-repository.mjs'

export async function activateStory(backlogPath, storyId) {
  const backlog = await readBacklog(backlogPath)
  const story = backlog.stories.find((candidate) => String(candidate.id) === String(storyId))
  if (!story) throw new Error(`Story ${storyId} not found.`)
  if (!story.story_path) throw new Error(`Story ${storyId} has no story_path.`)

  const updatedBacklog = {
    ...backlog,
    activeStoryId: story.id,
  }
  await writeBacklogAtomic(backlogPath, updatedBacklog)
  return story.id
}
