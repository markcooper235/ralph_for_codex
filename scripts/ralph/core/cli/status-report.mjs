import { buildStatusReport, renderStatusReport } from '../application/status-report.mjs'

const [workspaceRoot, ralphRoot, activeSprint = '', prepDetails = '0', prepStoryLimit = '5', loopState = 'stopped'] = process.argv.slice(2)
if (!workspaceRoot || !ralphRoot) {
  console.error('Usage: status-report.mjs <workspace-root> <ralph-root> [active-sprint] [prep-details] [prep-story-limit]')
  process.exitCode = 2
} else {
  try {
    const report = await buildStatusReport({ workspaceRoot, ralphRoot, activeSprint, prepDetails: prepDetails === '1', prepStoryLimit: Number(prepStoryLimit), loopState })
    process.stdout.write(`${process.env.RALPH_STATUS_JSON === '1' ? JSON.stringify(report) : renderStatusReport(report)}\n`)
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
