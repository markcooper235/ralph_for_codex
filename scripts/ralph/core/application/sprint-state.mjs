import { readFile, writeFile, rename } from 'node:fs/promises'
import { dirname } from 'node:path'
import { mkdir } from 'node:fs/promises'

async function readJson(path) {
  return JSON.parse(await readFile(path, 'utf8'))
}

async function writeJsonAtomic(path, value) {
  await mkdir(dirname(path), { recursive: true })
  const temporary = `${path}.${process.pid}.${Date.now()}.tmp`
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 })
  await rename(temporary, path)
}

export async function getSprintStatus(storiesPath) {
  try { return (await readJson(storiesPath)).status ?? 'planned' } catch { return 'planned' }
}

export async function setSprintStatus(storiesPath, status) {
  const stories = await readJson(storiesPath)
  await writeJsonAtomic(storiesPath, { ...stories, status })
  return status
}

export async function getActiveSprint(activeSprintPath) {
  try { return (await readFile(activeSprintPath, 'utf8')).split(/\r?\n/).find(Boolean) ?? '' } catch { return '' }
}

export async function setActiveSprint(activeSprintPath, sprint) {
  await mkdir(dirname(activeSprintPath), { recursive: true })
  await writeFile(activeSprintPath, `${sprint}\n`, { mode: 0o600 })
  return sprint
}
