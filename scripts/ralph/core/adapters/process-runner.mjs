import { spawn } from 'node:child_process'

function runtimeEnvironment(base = process.env, overrides = {}) {
  const runtimeHome = base.RALPH_RUNTIME_HOME_DIR
  const environment = { ...base, ...overrides }
  if (!runtimeHome) return environment
  return {
    ...environment,
    HOME: runtimeHome,
    CODEX_HOME: `${runtimeHome}/.codex`,
    XDG_CONFIG_HOME: `${runtimeHome}/.config`,
    XDG_CACHE_HOME: `${runtimeHome}/.cache`,
    XDG_STATE_HOME: `${runtimeHome}/.local/state`,
    XDG_DATA_HOME: `${runtimeHome}/.local/share`,
  }
}

export function runHarnessProcess(binary, args, {
  prompt,
  workspace,
  environment = {},
  timeoutMs = Number(process.env.RALPH_HARNESS_TIMEOUT_MS || 0),
  stdin = true,
} = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, args, {
      cwd: workspace,
      env: runtimeEnvironment(process.env, environment),
      stdio: [stdin ? 'pipe' : 'ignore', 'inherit', 'inherit'],
    })
    let settled = false
    let timer
    const finish = (code) => {
      if (settled) return
      settled = true
      if (timer) clearTimeout(timer)
      resolve(code)
    }
    child.once('error', (error) => {
      if (settled) return
      settled = true
      if (timer) clearTimeout(timer)
      reject(error)
    })
    child.once('close', (code, signal) => finish(code ?? (signal ? 1 : 0)))
    if (stdin) child.stdin.end(`${prompt ?? ''}\n`)
    if (timeoutMs > 0) {
      timer = setTimeout(() => {
        if (settled) return
        child.kill('SIGTERM')
        setTimeout(() => {
          if (!settled) child.kill('SIGKILL')
        }, 1000).unref()
        finish(124)
      }, timeoutMs)
      timer.unref()
    }
  })
}
