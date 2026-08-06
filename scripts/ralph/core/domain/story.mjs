export const STORY_STATUSES = Object.freeze([
  'planned',
  'ready',
  'active',
  'done',
  'abandoned',
  'blocked',
])

export function setStoryStatus(backlog, storyId, status) {
  if (!STORY_STATUSES.includes(status)) {
    throw new Error(`Invalid status '${status}'. Valid: ${STORY_STATUSES.join(' ')}`)
  }

  return {
    ...backlog,
    stories: backlog.stories.map((story) => (
      story.id === storyId ? { ...story, status } : story
    )),
  }
}

export function abandonStory(backlog, storyId, reason = '') {
  return {
    ...backlog,
    stories: backlog.stories.map((story) => (
      story.id === storyId
        ? { ...story, status: 'abandoned', abandonReason: reason }
        : story
    )),
  }
}
