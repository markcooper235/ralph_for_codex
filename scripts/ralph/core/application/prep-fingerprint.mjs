import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'

function focusFiles(focusHints = '') {
  return focusHints.split(/\r?\n/)
    .map((line) => line.match(/^\s*-\s*`(.*)`$/)?.[1])
    .filter(Boolean)
}

export async function computePrepFingerprint({ storyId, sprint, title, goal, promptContext, repoBriefingPath = '', commandMap = {}, dependsOn = [], focusHints = '', dependencyContext = '' }) {
  let repoBriefingHash = ''
  if (repoBriefingPath) {
    try { repoBriefingHash = createHash('sha256').update(await readFile(repoBriefingPath)).digest('hex') } catch { /* missing briefing is represented by empty hash */ }
  }
  const payload = {
    storyId, sprint, title, goal, promptContext, repoBriefingHash,
    commands: commandMap,
    dependsOn,
    likelyFiles: focusFiles(focusHints),
    dependencyContext,
  }
  return createHash('sha256').update(JSON.stringify(payload)).digest('hex')
}
