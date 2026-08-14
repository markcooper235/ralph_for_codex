import { spawn } from 'node:child_process'

function numericTimeout(value) {
  const timeout = Number(value || 0)
  return Number.isFinite(timeout) && timeout > 0 ? timeout : 0
}

/**
 * Execute one story check in the workspace and return a deterministic result.
 * Checks are deliberately executed by bash because they are a public story
 * format and may contain normal shell pipelines, redirects, and commands.
 * Node owns the process lifecycle, capture, and timeout semantics.
 */
export function runCheck(command, workspaceRoot, { timeoutMs = process.env.RALPH_CHECK_TIMEOUT_MS } = {}) {
  const timeout = numericTimeout(timeoutMs)

  return new Promise((resolve) => {
    const child = spawn('/bin/bash', ['-lc', command], {
      cwd: workspaceRoot,
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    const stdout = []
    const stderr = []
    let timedOut = false
    let settled = false
    let timer

    child.stdout.on('data', (chunk) => stdout.push(chunk))
    child.stderr.on('data', (chunk) => stderr.push(chunk))
    child.on('error', (error) => {
      if (settled) return
      settled = true
      resolve({ passed: false, exitCode: 127, signal: null, timedOut: false, stdout: Buffer.concat(stdout).toString(), stderr: `${Buffer.concat(stderr).toString()}${error.message}\n` })
    })
    child.on('close', (code, signal) => {
      if (settled) return
      settled = true
      if (timer) clearTimeout(timer)
      const exitCode = timedOut ? 124 : (typeof code === 'number' ? code : 1)
      resolve({
        passed: exitCode === 0,
        exitCode,
        signal: signal || null,
        timedOut,
        stdout: Buffer.concat(stdout).toString(),
        stderr: Buffer.concat(stderr).toString(),
      })
    })

    if (timeout > 0) {
      timer = setTimeout(() => {
        timedOut = true
        child.kill('SIGTERM')
        setTimeout(() => {
          if (!settled) child.kill('SIGKILL')
        }, 250)
      }, timeout)
    }
  })
}
