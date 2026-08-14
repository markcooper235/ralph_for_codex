import { listStories } from '../application/story-view.mjs'

const [backlogPath] = process.argv.slice(2)
if (!backlogPath) {
  console.error('Usage: story-list.mjs <stories.json>')
  process.exitCode = 2
} else {
  try {
    process.stdout.write(`${JSON.stringify(await listStories(backlogPath))}\n`)
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
