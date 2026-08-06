import { spawn } from 'node:child_process'
import { requireHarnessPort } from '../ports/harness.mjs'

function runProcess(binary, args, { prompt, workspace }) {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, ['-p', ...args, prompt], {
      cwd: workspace,
      stdio: ['ignore', 'inherit', 'inherit'],
      env: { ...process.env, PI_PERMISSION_LEVEL: 'bypassed' },
    })
    child.on('error', reject)
    child.on('close', (code, signal) => resolve(code ?? (signal ? 1 : 0)))
  })
}

/** @param {{ binary?: string }} options */
export function createPiProcessAdapter({ binary = process.env.PI_BIN || 'pi' } = {}) {
  return requireHarnessPort({
    execute: ({ prompt, workspace, args = [] }) => runProcess(binary, args, { prompt, workspace }),
  })
}
