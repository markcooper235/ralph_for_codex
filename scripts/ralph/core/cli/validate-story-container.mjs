import { validateStoryContainer } from '../application/story-container.mjs'

const [storyPath, storyId, sprint] = process.argv.slice(2)
if (!storyPath || !storyId || !sprint) {
  console.error('Usage: validate-story-container.mjs <story.json> <story-id> <sprint>')
  process.exitCode = 2
} else {
  try {
    await validateStoryContainer(storyPath, storyId, sprint)
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
