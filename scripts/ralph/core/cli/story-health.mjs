import { analyzeStoryHealth } from '../application/story-health.mjs'

const [storyPath, storyId, backlogStatus = ''] = process.argv.slice(2)
if (!storyPath || !storyId) {
  console.error('Usage: story-health.mjs <story.json> <story-id> [backlog-status]')
  process.exitCode = 2
} else {
  try {
    const result = await analyzeStoryHealth(storyPath, storyId, backlogStatus)
    process.stdout.write(`${result.messages.join('\n')}\n`)
    process.exitCode = result.healthy ? 0 : 1
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
