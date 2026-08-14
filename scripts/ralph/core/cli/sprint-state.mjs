import { getActiveSprint, getSprintStatus, setActiveSprint, setSprintStatus } from '../application/sprint-state.mjs'

const [command, path, value = ''] = process.argv.slice(2)
if (!command || !path || (['set-status', 'set-active'].includes(command) && !value)) {
  console.error('Usage: sprint-state.mjs <get-status|set-status|get-active|set-active> <path> [value]')
  process.exitCode = 2
} else {
  try {
    const result = command === 'get-status' ? await getSprintStatus(path)
      : command === 'set-status' ? await setSprintStatus(path, value)
        : command === 'get-active' ? await getActiveSprint(path)
          : command === 'set-active' ? await setActiveSprint(path, value) : null
    if (result !== null) process.stdout.write(`${result}\n`)
    else process.exitCode = 2
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
