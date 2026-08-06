import { spawn } from 'node:child_process'
import { requireHarnessPort } from '../ports/harness.mjs'

function supportsYolo(binary) {
  return new Promise((resolve) => {
    const child = spawn(binary, ['--yolo', 'exec', '--help'], { stdio: ['ignore', 'pipe', 'pipe'] })
    let output = ''
    child.stdout.on('data', (chunk) => { output += chunk })
    child.stderr.on('data', (chunk) => { output += chunk })
    child.on('error', () => resolve(false))
    child.on('close', () => resolve(!/unexpected argument '--yolo'/i.test(output) && /Run Codex non-interactively/i.test(output)))
  })
}

function runProcess(binary, args, { prompt, workspace }) {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, args, { cwd: workspace, stdio: ['pipe', 'inherit', 'inherit'] })
    child.on('error', reject)
    child.on('close', (code, signal) => resolve(code ?? (signal ? 1 : 0)))
    child.stdin.end(`${prompt}\n`)
  })
}

/** @param {{ binary?: string }} options */
export function createCodexProcessAdapter({ binary = process.env.CODEX_BIN || 'codex' } = {}) {
  const adapter = {
    async execute({ prompt, workspace, args = [] }) {
      const yolo = await supportsYolo(binary)
      const modeArgs = yolo
        ? ['--yolo', 'exec']
        : ['exec', '--dangerously-bypass-approvals-and-sandbox']
      return runProcess(binary, [...modeArgs, ...args], { prompt, workspace })
    },
  }
  return requireHarnessPort(adapter)
}
