import { runCheck } from '../application/check-runner.mjs'

const [workspaceRoot, timeoutMs = '0', command] = process.argv.slice(2)

if (!workspaceRoot || !command) {
  console.error('Usage: run-check.mjs <workspace-root> [timeout-ms] <command>')
  process.exitCode = 2
} else {
  try {
    const result = await runCheck(command, workspaceRoot, { timeoutMs })
    process.stdout.write(`${JSON.stringify(result)}\n`)
    process.exitCode = result.passed ? 0 : result.exitCode
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
