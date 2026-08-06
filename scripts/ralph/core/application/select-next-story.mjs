import { readBacklog } from '../repositories/backlog-repository.mjs'
import { selectNextStory } from '../domain/sprint.mjs'

export async function selectNextStoryId(backlogPath) {
  const backlog = await readBacklog(backlogPath)
  return selectNextStory(backlog.stories)?.id ?? null
}
