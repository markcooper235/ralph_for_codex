import { computePrepFingerprint } from '../application/prep-fingerprint.mjs'

const [storyId, sprint, title, goal, promptContext, repoBriefingPath, commandMapJson, dependsOnJson, focusHints, dependencyContext = ''] = process.argv.slice(2)
if (!storyId || !sprint || !commandMapJson || !dependsOnJson) {
  console.error('Usage: prep-fingerprint.mjs <story-id> <sprint> <title> <goal> <prompt> <briefing> <commands-json> <depends-json> [focus-hints] [dependency-context]')
  process.exitCode = 2
} else {
  try {
    process.stdout.write(`${await computePrepFingerprint({ storyId, sprint, title, goal, promptContext, repoBriefingPath, commandMap: JSON.parse(commandMapJson), dependsOn: JSON.parse(dependsOnJson), focusHints, dependencyContext })}\n`)
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
