import {
  getStoryMetadata,
  getTaskChecks,
  getTaskIds,
  getTaskPasses,
  getTaskStatus,
} from '../application/story-query.mjs'

const [command, storyPath, value = ''] = process.argv.slice(2)

if (!command || !storyPath || (command === 'task-checks' && !value)) {
  console.error('Usage: story-query.mjs <task-ids|task-checks|task-status|task-passes|metadata> <story.json> [TASK_ID|TARGET_ID]')
  process.exitCode = 2
} else {
  try {
    const result = command === 'task-ids'
      ? await getTaskIds(storyPath, value)
      : command === 'task-checks'
        ? await getTaskChecks(storyPath, value)
        : command === 'task-status'
          ? await getTaskStatus(storyPath, value)
          : command === 'task-passes'
            ? await getTaskPasses(storyPath, value)
        : command === 'metadata'
          ? await getStoryMetadata(storyPath)
          : null
    if (result === null) {
      console.error(`Unknown story query: ${command}`)
      process.exitCode = 2
    } else {
      process.stdout.write(`${JSON.stringify(result)}\n`)
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
