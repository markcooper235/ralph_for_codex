import { getTaskVerificationDecision, isStoryComplete } from '../application/verification.mjs'

const [command, storyPath, taskId = '', failureSeen = 'false'] = process.argv.slice(2)

function usage() {
  console.error('Usage: verification.mjs <story-complete|task-decision> <story.json> [TASK_ID] [FAILURE_SEEN]')
  process.exitCode = 2
}

if (!command || !storyPath || (command === 'task-decision' && !taskId)) {
  usage()
} else {
  try {
    if (command === 'story-complete') {
      process.exitCode = await isStoryComplete(storyPath) ? 0 : 1
    } else if (command === 'task-decision') {
      const decision = await getTaskVerificationDecision(storyPath, taskId, failureSeen === 'true')
      process.stdout.write(`${decision.state}\n`)
    } else {
      usage()
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
