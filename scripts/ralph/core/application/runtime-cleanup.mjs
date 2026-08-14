import { readdir, rm } from 'node:fs/promises'
import { join } from 'node:path'

export async function pruneRuntimeRuns(root, keepCount = 3) {
  if (!root || !Number.isInteger(Number(keepCount)) || Number(keepCount) < 0) throw new Error('Runtime cleanup requires a non-negative keep count')
  let entries
  try { entries = await readdir(root, { withFileTypes: true }) } catch { return [] }
  const directories = entries.filter((entry) => entry.isDirectory()).map((entry) => entry.name).sort()
  const removed = directories.slice(0, Math.max(0, directories.length - Number(keepCount)))
  for (const name of removed) await rm(join(root, name), { recursive: true, force: true })
  return removed.map((name) => join(root, name))
}
