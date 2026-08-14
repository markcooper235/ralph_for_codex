import { finalizePrepSummary, recordPrepStage, rollupPrepStages, touchPrepSummary } from '../application/prep-journal.mjs'

const [command, runDir, ...args] = process.argv.slice(2)
if (!command || !runDir) {
  console.error('Usage: prep-journal.mjs <record|touch|finalize|rollup> <run-dir> ...')
  process.exitCode = 2
} else {
  try {
    if (command === 'record') {
      const [storyId, stage, status, detail = '', artifactsJson = '[]', durationMs = '0', profileJson = 'null'] = args
      await recordPrepStage({ runDir, storyId, stage, status, detail, artifacts: JSON.parse(artifactsJson), durationMs, executionProfile: JSON.parse(profileJson) })
    } else if (command === 'touch') {
      const [phase = '', storyId = '', stage = '', profileJson = 'null'] = args
      await touchPrepSummary({ runDir, phase, activeStoryId: storyId, activeStage: stage, executionProfile: JSON.parse(profileJson) })
    } else if (command === 'finalize') {
      await finalizePrepSummary(runDir, args[0])
    } else if (command === 'rollup') {
      process.stdout.write(`${JSON.stringify(await rollupPrepStages(runDir))}\n`)
    } else process.exitCode = 2
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
