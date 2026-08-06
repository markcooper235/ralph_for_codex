import { readFile } from 'node:fs/promises'

export async function readStory(filePath) {
  let raw
  try {
    raw = await readFile(filePath, 'utf8')
  } catch (error) {
    throw new Error(`Unable to read story file: ${filePath}`, { cause: error })
  }
  let story
  try {
    story = JSON.parse(raw)
  } catch (error) {
    throw new Error(`Invalid story JSON: ${filePath}`, { cause: error })
  }
  if (!story || typeof story !== 'object' || !Array.isArray(story.tasks)) {
    throw new Error(`Invalid story shape: ${filePath}`)
  }
  return story
}
