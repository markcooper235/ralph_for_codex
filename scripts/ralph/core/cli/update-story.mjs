import { completeStory, updateTaskResult } from '../application/update-story.mjs'

const [command, storyPath, id, passed = ''] = process.argv.slice(2)

function usage() {
  console.error('Usage: update-story.mjs <set-task-result|complete> <story.json> [TASK_ID] [true|false]')
  process.exitCode = 2
}

if (!command || !storyPath || (command === 'set-task-result' && (!id || !['true', 'false'].includes(passed)))) {
  usage()
} else {
  try {
    if (command === 'set-task-result') {
      await updateTaskResult(storyPath, id, passed === 'true')
    } else if (command === 'complete') {
      await completeStory(storyPath)
    } else {
      usage()
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
