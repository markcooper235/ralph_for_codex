import { buildDependencyHandoff } from '../application/dependency-handoff.mjs'

const [storyPath, backlogPath, workspaceRoot] = process.argv.slice(2)

if (!storyPath || !backlogPath || !workspaceRoot) {
  console.error('Usage: dependency-handoff.mjs <story.json> <stories.json> <workspace>')
  process.exitCode = 2
} else {
  try {
    process.stdout.write(`${JSON.stringify(await buildDependencyHandoff(storyPath, backlogPath, workspaceRoot))}\n`)
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
