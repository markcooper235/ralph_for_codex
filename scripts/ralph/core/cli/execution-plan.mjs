import { buildExecutionChecks } from '../application/execution-plan.mjs'

const [command, storyPath, targetTaskId = ''] = process.argv.slice(2)

if (command !== 'checks' || !storyPath) {
  console.error('Usage: execution-plan.mjs checks <story.json> [TASK_ID]')
  process.exitCode = 2
} else {
  try {
    process.stdout.write(`${JSON.stringify(await buildExecutionChecks(storyPath, targetTaskId))}\n`)
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
