import { createCodexProcessAdapter } from '../adapters/codex-process.mjs'

const [prompt = '', workspace = '', ...rawArgs] = process.argv.slice(2)
const delimiter = rawArgs.indexOf('--')
const args = delimiter === -1 ? rawArgs : rawArgs.slice(0, delimiter).concat(rawArgs.slice(delimiter + 1))

if (!prompt || !workspace) {
  console.error('Usage: codex-exec.mjs <prompt> <workspace> [codex-flags...] -- [passthrough-flags...]')
  process.exitCode = 2
} else {
  try {
    process.exitCode = await createCodexProcessAdapter().execute({ prompt, workspace, args })
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
