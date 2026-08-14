import { readdir, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)

export async function pruneArchiveRetention(archiveRoot, keepCount = 7) {
  if (!archiveRoot || !Number.isInteger(Number(keepCount)) || Number(keepCount) < 0) throw new Error('Archive retention requires a non-negative keep count')
  let entries
  try { entries = await readdir(archiveRoot, { withFileTypes: true }) } catch { return [] }
  const directories = entries.filter((entry) => entry.isDirectory()).map((entry) => entry.name).sort().reverse()
  const removed = []
  for (const name of directories.slice(Number(keepCount))) {
    const directory = join(archiveRoot, name)
    const zipPath = join(archiveRoot, `${name}.zip`)
    try {
      await execFileAsync('zip', ['-rq', zipPath, name], { cwd: archiveRoot })
      await rm(directory, { recursive: true, force: true })
      removed.push(zipPath)
    } catch (error) {
      throw new Error(`Unable to compress archived sprint ${name}`, { cause: error })
    }
  }
  return removed
}
