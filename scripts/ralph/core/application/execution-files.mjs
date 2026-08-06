import { readFile } from 'node:fs/promises'
import { readStory } from '../repositories/story-repository.mjs'
import { extractCheckFile, sanitizePaths } from '../domain/paths.mjs'

export async function buildExecutionFiles(storyPath, contextPath, targetTaskId = '') {
  const story = await readStory(storyPath)
  const context = JSON.parse(await readFile(contextPath, 'utf8'))
  const tasks = (story.tasks ?? [])
    .filter((task) => task.passes !== true)
    .filter((task) => !targetTaskId || String(task.id) === String(targetTaskId))
  const scopes = tasks.flatMap((task) => task.scope ?? [])
  const nearestTests = tasks.flatMap((task) => (task.checks ?? []).map(extractCheckFile)).filter(Boolean)
  const dependencyFiles = (context.dependency_handoff ?? []).flatMap((entry) => entry.files_touched ?? [])
  return {
    writable_scope: sanitizePaths(scopes),
    nearest_tests: sanitizePaths(nearestTests),
    dependency_files: sanitizePaths(dependencyFiles),
    blocked_paths: [
      'node_modules/**', '.next/**', 'coverage/**', 'dist/**', 'build/**',
      'vendor/**', 'scripts/ralph/runtime/**', 'dist-docs/**',
      'scripts/ralph/README-local.md', 'scripts/ralph/doctor.sh',
      'scripts/ralph/lib/specify.sh',
    ],
  }
}
