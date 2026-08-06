export function validateStory(story) {
  if (!story || typeof story !== 'object' || !Array.isArray(story.tasks)) {
    throw new Error('Invalid story shape: tasks must be an array')
  }
  for (const task of story.tasks) {
    if (!task || typeof task !== 'object' || typeof task.id !== 'string' || !task.id) {
      throw new Error('Invalid story shape: every task must have a string id')
    }
  }
  return story
}

export function validateBacklog(backlog) {
  if (!backlog || typeof backlog !== 'object' || !Array.isArray(backlog.stories)) {
    throw new Error('Invalid stories backlog shape: stories must be an array')
  }
  for (const story of backlog.stories) {
    if (!story || typeof story !== 'object' || typeof story.id !== 'string' || !story.id) {
      throw new Error('Invalid stories backlog shape: every story must have a string id')
    }
  }
  return backlog
}
