import { selectNextStoryId } from '../application/select-next-story.mjs'

const backlogPath = process.argv[2]

if (!backlogPath) {
  console.error('Usage: next-id.mjs <stories.json>')
  process.exitCode = 2
} else {
  try {
    const storyId = await selectNextStoryId(backlogPath)
    if (storyId !== null) process.stdout.write(`${storyId}\n`)
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
