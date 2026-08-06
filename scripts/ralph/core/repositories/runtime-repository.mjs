import { mkdir, open, rename, unlink } from 'node:fs/promises'
import { dirname } from 'node:path'

export async function writeRuntimeJson(filePath, value) {
  const directory = dirname(filePath)
  await mkdir(directory, { recursive: true })
  const temporaryPath = `${filePath}.${process.pid}.${Date.now()}.tmp`
  let handle
  try {
    handle = await open(temporaryPath, 'wx', 0o600)
    await handle.writeFile(`${JSON.stringify(value, null, 2)}\n`, 'utf8')
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
    throw new Error(`Unable to write runtime JSON atomically: ${filePath}`, { cause: error })
  }
}
