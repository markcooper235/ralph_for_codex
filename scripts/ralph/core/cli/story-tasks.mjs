import { getStoryTasks } from '../application/story-view.mjs'

const [backlogPath, storyId] = process.argv.slice(2)
if (!backlogPath || !storyId) {
  console.error('Usage: story-tasks.mjs <stories.json> <ID>')
  process.exitCode = 2
} else {
  try {
    process.stdout.write(`${JSON.stringify(await getStoryTasks(backlogPath, storyId), null, 2)}\n`)
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
