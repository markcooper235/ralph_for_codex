import { fingerprintCheck } from '../application/check-fingerprint.mjs'

const [storyPath, workspaceRoot, taskId, check] = process.argv.slice(2)

if (!storyPath || !workspaceRoot || !taskId || !check) {
  console.error('Usage: check-fingerprint.mjs <story.json> <workspace-root> <TASK_ID> <check>')
  process.exitCode = 2
} else {
  try {
    process.stdout.write(`${await fingerprintCheck(storyPath, workspaceRoot, taskId, check)}\n`)
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
