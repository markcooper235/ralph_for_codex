import { buildProjectCommandMap } from '../application/project-commands.mjs'

const [workspaceRoot] = process.argv.slice(2)

if (!workspaceRoot) {
  console.error('Usage: project-commands.mjs <workspace>')
  process.exitCode = 2
} else {
  try {
    process.stdout.write(`${JSON.stringify(await buildProjectCommandMap(workspaceRoot))}\n`)
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
