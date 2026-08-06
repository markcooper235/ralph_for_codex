export const TASK_STATUSES = ['pending', 'active', 'done', 'failed', 'blocked']

function taskById(story, taskId) {
  return (story.tasks ?? []).find((task) => String(task.id) === String(taskId))
}

export function taskPasses(story, taskId) {
  return taskById(story, taskId)?.passes === true
}

export function taskDependenciesMet(story, taskId) {
  const task = taskById(story, taskId)
  if (!task) return false
  return (task.depends_on ?? []).every((dependencyId) => taskPasses(story, dependencyId))
}

/**
 * Decide whether the verifier may run a task, matching the shell verifier's
 * dependency blocking and fail-fast behavior.
 */
export function verificationDecision(story, taskId, failureSeen = false) {
  const dependenciesMet = taskDependenciesMet(story, taskId)
  if (failureSeen && !dependenciesMet) return { state: 'blocked', failureSeen: true }
  if (!dependenciesMet) return { state: 'blocked', failureSeen: true }
  return { state: 'ready', failureSeen }
}

export function applyTaskResult(story, taskId, passed) {
  return {
    ...story,
    tasks: (story.tasks ?? []).map((task) => (
      String(task.id) === String(taskId)
        ? { ...task, status: passed ? 'done' : 'failed', passes: passed }
        : task
    )),
  }
}

export function storyIsComplete(story) {
  return story.status === 'done'
    && story.passes === true
    && (story.tasks ?? []).every((task) => task.passes === true)
}
