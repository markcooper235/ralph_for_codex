import { writeStoryRuntimeManifest } from '../application/story-runtime.mjs'

const [manifestPath, ...values] = process.argv.slice(2)

if (!manifestPath || values.length !== 20) {
  console.error('Usage: story-runtime.mjs <manifest.json> <20 manifest values>')
  process.exitCode = 2
} else {
  try {
    await writeStoryRuntimeManifest(manifestPath, values)
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
