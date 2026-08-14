import { writeFallowReport } from '../application/fallow-report.mjs'

const [reportPath, storyId, filesJson = '[]', fallowIssues = '', deadCodeIssues = ''] = process.argv.slice(2)
if (!reportPath || !storyId) {
  console.error('Usage: fallow-report.mjs <report-path> <story-id> [files-json] [fallow-issues] [dead-code-issues]')
  process.exitCode = 2
} else {
  try { await writeFallowReport({ reportPath, storyId, files: JSON.parse(filesJson), fallowIssues, deadCodeIssues }) }
  catch (error) { console.error(error instanceof Error ? error.message : String(error)); process.exitCode = 1 }
}
