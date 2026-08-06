import { buildExecutionContext } from '../application/execution-context.mjs'

const [storyPath, dependencyPath, targetTaskId = ''] = process.argv.slice(2)

if (!storyPath || !dependencyPath) {
  console.error('Usage: execution-context.mjs <story.json> <dependency-handoff.json> [TASK_ID]')
  process.exitCode = 2
} else {
  try {
    process.stdout.write(`${JSON.stringify(await buildExecutionContext(storyPath, dependencyPath, targetTaskId))}\n`)
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
