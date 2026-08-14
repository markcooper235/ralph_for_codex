import { runTaskChecks } from '../application/task-check-runner.mjs'

const [storyPath, workspaceRoot, taskId, timeoutMs = '0'] = process.argv.slice(2)
if (!storyPath || !workspaceRoot || !taskId) {
  console.error('Usage: run-task-checks.mjs <story.json> <workspace-root> <TASK_ID> [timeout-ms]')
  process.exitCode = 2
} else {
  try {
    const result = await runTaskChecks(storyPath, workspaceRoot, taskId, timeoutMs)
    process.stdout.write(`${JSON.stringify(result)}\n`)
    process.exitCode = result.passed ? 0 : 1
  } catch (error) { console.error(error instanceof Error ? error.message : String(error)); process.exitCode = 1 }
}
