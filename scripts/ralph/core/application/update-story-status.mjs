import { readBacklog, writeBacklogAtomic } from '../repositories/backlog-repository.mjs'
import { abandonStory, setStoryStatus } from '../domain/story.mjs'

export async function updateStoryStatus(backlogPath, storyId, status) {
  const backlog = await readBacklog(backlogPath)
  const updatedBacklog = setStoryStatus(backlog, storyId, status)
  await writeBacklogAtomic(backlogPath, updatedBacklog)
}

export async function abandonStoryById(backlogPath, storyId, reason = '') {
  const backlog = await readBacklog(backlogPath)
  const updatedBacklog = abandonStory(backlog, storyId, reason)
  await writeBacklogAtomic(backlogPath, updatedBacklog)
}
