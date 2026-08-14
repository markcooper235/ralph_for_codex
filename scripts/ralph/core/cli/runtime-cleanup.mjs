import { pruneRuntimeRuns } from '../application/runtime-cleanup.mjs'

const [root, keepCount = '3'] = process.argv.slice(2)
if (!root) {
  console.error('Usage: runtime-cleanup.mjs <runtime-runs-root> [keep-count]')
  process.exitCode = 2
} else {
  try { process.stdout.write(`${JSON.stringify(await pruneRuntimeRuns(root, Number(keepCount)))}\n`) }
  catch (error) { console.error(error instanceof Error ? error.message : String(error)); process.exitCode = 1 }
}
