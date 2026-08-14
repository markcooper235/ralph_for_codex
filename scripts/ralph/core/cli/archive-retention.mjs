import { pruneArchiveRetention } from '../application/archive-retention.mjs'

const [archiveRoot, keepCount = '7'] = process.argv.slice(2)
if (!archiveRoot) {
  console.error('Usage: archive-retention.mjs <archive-root> [keep-count]')
  process.exitCode = 2
} else {
  try { process.stdout.write(`${JSON.stringify(await pruneArchiveRetention(archiveRoot, Number(keepCount)))}\n`) }
  catch (error) { console.error(error instanceof Error ? error.message : String(error)); process.exitCode = 1 }
}
