/**
 * @typedef {Object} HarnessPort
 * @property {(options: { prompt: string, workspace: string, args?: string[] }) => Promise<number>} execute
 */

/** @param {HarnessPort} harness */
export function requireHarnessPort(harness) {
  if (!harness || typeof harness.execute !== 'function') {
    throw new TypeError('Harness port must implement: execute')
  }
  return harness
}
