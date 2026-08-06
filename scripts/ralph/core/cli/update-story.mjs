import {
  completeStory,
  updateStoryField,
  updateTaskField,
  updateTaskResult,
} from '../application/update-story.mjs'

const [command, storyPath, id, fieldOrValue = '', rawValue = ''] = process.argv.slice(2)
const value = fieldOrValue

function usage() {
  console.error('Usage: update-story.mjs <set-task-result|set-task-field|set-story-field|complete> <story.json> [ID] [VALUE]')
  process.exitCode = 2
}

if (!command || !storyPath || (command === 'set-task-result' && (!id || !['true', 'false'].includes(value)))
  || (command === 'set-task-field' && (!id || !fieldOrValue || !rawValue))
  || (command === 'set-story-field' && (!id || !fieldOrValue))) {
  usage()
} else {
  try {
    if (command === 'set-task-result') {
      await updateTaskResult(storyPath, id, value === 'true')
    } else if (command === 'set-task-field') {
      await updateTaskField(storyPath, id, fieldOrValue, JSON.parse(rawValue))
    } else if (command === 'set-story-field') {
      await updateStoryField(storyPath, id, JSON.parse(fieldOrValue))
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
