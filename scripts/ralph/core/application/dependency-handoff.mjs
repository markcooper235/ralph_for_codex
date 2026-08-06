import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { readBacklog } from '../repositories/backlog-repository.mjs'

async function readOptionalStory(filePath) {
  try {
    return JSON.parse(await readFile(filePath, 'utf8'))
  } catch {
    return null
  }
}

export async function buildDependencyHandoff(storyPath, backlogPath, workspaceRoot) {
  const story = JSON.parse(await readFile(storyPath, 'utf8'))
  const backlog = await readBacklog(backlogPath)
  const entries = []
  for (const dependencyId of story.depends_on ?? []) {
    const dependency = backlog.stories.find((candidate) => String(candidate.id) === String(dependencyId))
    if (!dependency?.story_path) continue
    const dependencyPath = resolve(workspaceRoot, dependency.story_path)
    const dependencyStory = await readOptionalStory(dependencyPath)
    if (!dependencyStory) continue
    entries.push({
      id: dependencyId,
      title: dependencyStory.title ?? '',
      files_touched: dependencyStory.story_handoff?.files_touched ?? [],
      contracts_added: dependencyStory.story_handoff?.contracts_added ?? [],
      residual_risks: dependencyStory.story_handoff?.residual_risks ?? [],
    })
  }
  return entries
}
