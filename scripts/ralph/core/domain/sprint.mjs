function compareJsonValues(left, right) {
  if (left === right) return 0
  if (left === null || left === undefined) return -1
  if (right === null || right === undefined) return 1
  return left < right ? -1 : 1
}

function compareStories(left, right) {
  const priorityOrder = compareJsonValues(left.priority, right.priority)
  if (priorityOrder !== 0) return priorityOrder
  return compareJsonValues(String(left.id ?? ''), String(right.id ?? ''))
}

function dependencyIsDone(storiesById, dependencyId) {
  const dependency = storiesById.get(String(dependencyId))
  // Match the Bash/JQ implementation: unknown dependency IDs do not block
  // selection; health validation reports malformed dependencies separately.
  return !dependency || dependency.status === 'done'
}

export function selectNextStory(stories) {
  const storiesById = new Map(stories.map((story) => [String(story.id), story]))
  const candidates = stories
    .filter((story) => story.status === 'ready' || story.status === 'planned')
    .slice()
    .sort(compareStories)

  return candidates.find((story) => {
    const dependencies = Array.isArray(story.depends_on) ? story.depends_on : []
    return dependencies.every((dependencyId) => dependencyIsDone(storiesById, dependencyId))
  }) ?? null
}
