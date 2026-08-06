import { buildExecutionFiles } from '../application/execution-files.mjs'

const [storyPath, contextPath, targetTaskId = ''] = process.argv.slice(2)

if (!storyPath || !contextPath) {
  console.error('Usage: execution-files.mjs <story.json> <context.json> [TASK_ID]')
  process.exitCode = 2
} else {
  try {
    process.stdout.write(`${JSON.stringify(await buildExecutionFiles(storyPath, contextPath, targetTaskId))}\n`)
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
