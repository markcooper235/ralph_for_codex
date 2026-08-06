import { readFile } from 'node:fs/promises'

export async function readBacklog(filePath) {
  let raw
  try {
    raw = await readFile(filePath, 'utf8')
  } catch (error) {
    throw new Error(`Unable to read stories backlog: ${filePath}`, { cause: error })
  }

  let backlog
  try {
    backlog = JSON.parse(raw)
  } catch (error) {
    throw new Error(`Invalid stories backlog JSON: ${filePath}`, { cause: error })
  }

  if (!backlog || typeof backlog !== 'object' || !Array.isArray(backlog.stories)) {
    throw new Error(`Invalid stories backlog shape: ${filePath}`)
  }

  return backlog
}
