import { abandonStoryById, updateStoryStatus } from '../application/update-story-status.mjs'

const [command, backlogPath, storyId, value = ''] = process.argv.slice(2)

function usage() {
  console.error('Usage: update-story-status.mjs <set-status|abandon> <stories.json> <ID> [STATUS|REASON]')
  process.exitCode = 2
}

if (!command || !backlogPath || !storyId) {
  usage()
} else {
  try {
    if (command === 'set-status') {
      await updateStoryStatus(backlogPath, storyId, value)
      process.stdout.write(`Story ${storyId} status set to: ${value}\n`)
    } else if (command === 'abandon') {
      await abandonStoryById(backlogPath, storyId, value)
      process.stdout.write(`Story ${storyId} marked abandoned.\n`)
    } else {
      usage()
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
