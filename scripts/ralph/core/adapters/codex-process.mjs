import { spawn } from 'node:child_process'
import { requireHarnessPort } from '../ports/harness.mjs'
import { runHarnessProcess } from './process-runner.mjs'

const yoloSupport = new Map()

function supportsYolo(binary) {
  if (yoloSupport.has(binary)) return yoloSupport.get(binary)
  const result = new Promise((resolve) => {
    const child = spawn(binary, ['--yolo', 'exec', '--help'], { stdio: ['ignore', 'pipe', 'pipe'] })
    let output = ''
    child.stdout.on('data', (chunk) => { output += chunk })
    child.stderr.on('data', (chunk) => { output += chunk })
    child.on('error', () => resolve(false))
    child.on('close', () => resolve(!/unexpected argument '--yolo'/i.test(output) && /Run Codex non-interactively/i.test(output)))
  })
  yoloSupport.set(binary, result)
  return result
}

/** @param {{ binary?: string }} options */
export function createCodexProcessAdapter({ binary = process.env.CODEX_BIN || 'codex' } = {}) {
  const adapter = {
    async execute({ prompt, workspace, args = [] }) {
      const yolo = await supportsYolo(binary)
      const modeArgs = yolo
        ? ['--yolo', 'exec']
        : ['exec', '--dangerously-bypass-approvals-and-sandbox']
      return runHarnessProcess(binary, [...modeArgs, ...args], { prompt, workspace })
    },
  }
  return requireHarnessPort(adapter)
}
