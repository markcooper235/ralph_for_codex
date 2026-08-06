import { startNextStory } from '../application/start-next-story.mjs'

const [backlogPath] = process.argv.slice(2)

if (!backlogPath) {
  console.error('Usage: start-next.mjs <stories.json>')
  process.exitCode = 2
} else {
  try {
    process.stdout.write(`${await startNextStory(backlogPath)}\n`)
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
