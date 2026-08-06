/**
 * @typedef {Object} GitPort
 * @property {(branchName: string) => Promise<boolean>} hasBranch
 * @property {(branchName: string, startPoint?: string) => Promise<void>} createBranch
 * @property {(branchName: string) => Promise<void>} checkout
 * @property {(branchName: string) => Promise<string>} branchParent
 * @property {(branchName: string, parentBranch: string) => Promise<void>} setBranchParent
 */

/**
 * Validate the small Git capability surface used by story lifecycle services.
 * The process-backed adapter will be added separately; application code only
 * depends on this port and remains unaware of Git commands.
 *
 * @param {GitPort} git
 * @returns {GitPort}
 */
export function requireGitPort(git) {
  const methods = ['hasBranch', 'createBranch', 'checkout', 'branchParent', 'setBranchParent']
  if (!git || methods.some((method) => typeof git[method] !== 'function')) {
    throw new TypeError(`Git port must implement: ${methods.join(', ')}`)
  }
  return git
}
