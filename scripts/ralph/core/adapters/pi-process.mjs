import { requireHarnessPort } from '../ports/harness.mjs'
import { runHarnessProcess } from './process-runner.mjs'

/** @param {{ binary?: string }} options */
export function createPiProcessAdapter({ binary = process.env.PI_BIN || 'pi' } = {}) {
  return requireHarnessPort({
    execute: ({ prompt, workspace, args = [] }) => runHarnessProcess(binary, ['-p', ...args, prompt], {
      workspace,
      stdin: false,
      environment: { PI_PERMISSION_LEVEL: 'bypassed' },
    }),
  })
}
