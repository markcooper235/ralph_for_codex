import { execFile } from 'node:child_process'
import { access } from 'node:fs/promises'
import { promisify } from 'node:util'
import { resolve } from 'node:path'
import { readStory } from '../repositories/story-repository.mjs'
import { extractCheckFile, sanitizePaths } from '../domain/paths.mjs'

const execFileAsync = promisify(execFile)

async function fileFingerprint(workspaceRoot, relativePath) {
  const absolutePath = resolve(workspaceRoot, relativePath)
  try {
    await access(absolutePath)
  } catch {
    return `ABSENT:${relativePath}`
  }
  try {
    const { stdout } = await execFileAsync('git', ['-C', workspaceRoot, 'hash-object', absolutePath], { encoding: 'utf8' })
    return stdout.trim() || 'UNHASHED'
  } catch {
    return 'UNHASHED'
  }
}

export async function fingerprintCheck(storyPath, workspaceRoot, taskId, check) {
  const story = await readStory(storyPath)
  const reference = extractCheckFile(check)
  if (reference) return fileFingerprint(workspaceRoot, reference)

  const task = story.tasks.find((candidate) => String(candidate.id) === String(taskId))
  const paths = sanitizePaths(task?.scope ?? [])
  if (paths.length === 0) return 'EMPTY'
  const fingerprints = []
  for (const path of paths) fingerprints.push(await fileFingerprint(workspaceRoot, path))
  return fingerprints.join('') || 'EMPTY'
}
