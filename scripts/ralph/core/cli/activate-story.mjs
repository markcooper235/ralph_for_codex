import { activateStory } from '../application/activate-story.mjs'

const [backlogPath, storyId] = process.argv.slice(2)
if (!backlogPath || !storyId) {
  console.error('Usage: activate-story.mjs <stories.json> <ID>')
  process.exitCode = 2
} else {
  try {
    const activatedId = await activateStory(backlogPath, storyId)
    process.stdout.write(`Active story set to: ${activatedId}\n`)
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
