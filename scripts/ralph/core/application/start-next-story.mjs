import { readBacklog, writeBacklogAtomic } from '../repositories/backlog-repository.mjs'
import { selectNextStory } from '../domain/sprint.mjs'

export async function startNextStory(backlogPath) {
  const backlog = await readBacklog(backlogPath)
  const nextStory = selectNextStory(backlog.stories)
  if (!nextStory) throw new Error('No eligible story to start.')

  const updatedBacklog = {
    ...backlog,
    activeStoryId: nextStory.id,
    stories: backlog.stories.map((story) => (
      story.id === nextStory.id ? { ...story, status: 'active' } : story
    )),
  }
  await writeBacklogAtomic(backlogPath, updatedBacklog)
  return nextStory.id
}
