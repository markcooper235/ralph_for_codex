import { mkdir, open, readFile, rename, unlink } from 'node:fs/promises'
import { dirname } from 'node:path'
import { validateStory } from '../domain/validation.mjs'

export async function readStory(filePath) {
  let raw
  try {
    raw = await readFile(filePath, 'utf8')
  } catch (error) {
    throw new Error(`Unable to read story file: ${filePath}`, { cause: error })
  }
  let story
  try {
    story = JSON.parse(raw)
  } catch (error) {
    throw new Error(`Invalid story JSON: ${filePath}`, { cause: error })
  }
  try {
    return validateStory(story)
  } catch (error) {
    throw new Error(`${error.message}: ${filePath}`, { cause: error })
  }
}

export async function writeStoryAtomic(filePath, story) {
  const directory = dirname(filePath)
  await mkdir(directory, { recursive: true })
  const temporaryPath = `${filePath}.${process.pid}.${Date.now()}.tmp`
  const contents = `${JSON.stringify(story, null, 2)}\n`
  let handle
  try {
    handle = await open(temporaryPath, 'wx', 0o600)
    await handle.writeFile(contents, 'utf8')
    await handle.sync()
    await handle.close()
    handle = undefined
    await rename(temporaryPath, filePath)
    const directoryHandle = await open(directory, 'r')
    try {
      await directoryHandle.sync()
    } finally {
      await directoryHandle.close()
    }
  } catch (error) {
    if (handle) await handle.close().catch(() => {})
    await unlink(temporaryPath).catch(() => {})
    throw new Error(`Unable to write story atomically: ${filePath}`, { cause: error })
  }
}
