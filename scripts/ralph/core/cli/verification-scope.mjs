import { collectChangedFiles, collectSprintScope, collectStoryScope } from '../application/verification-scope.mjs'

const [mode, workspaceRoot, storyPath = '', taskId = '', sprintBranch = ''] = process.argv.slice(2)
if (!mode || !workspaceRoot) {
  console.error('Usage: verification-scope.mjs <changed|story|task|sprint> <workspace-root> [story.json] [task-id] [sprint-branch]')
  process.exitCode = 2
} else {
  try {
    const result = mode === 'changed' ? await collectChangedFiles(workspaceRoot)
      : mode === 'story' ? await collectStoryScope(storyPath)
        : mode === 'task' ? await collectStoryScope(storyPath, taskId)
          : mode === 'sprint' ? await collectSprintScope(workspaceRoot, sprintBranch) : null
    if (result === null) process.exitCode = 2
    else process.stdout.write(`${result.join('\n')}${result.length ? '\n' : ''}`)
  } catch (error) { console.error(error instanceof Error ? error.message : String(error)); process.exitCode = 1 }
}
