import { execFile } from 'node:child_process'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)

async function runGit(cwd, args, options = {}) {
  return execFileAsync('git', ['-C', cwd, ...args], {
    encoding: 'utf8',
    ...options,
  })
}

export function createGitProcessAdapter({ cwd }) {
  if (!cwd) throw new TypeError('Git process adapter requires a workspace path')

  return {
    async hasBranch(branchName) {
      try {
        await runGit(cwd, ['show-ref', '--verify', '--quiet', `refs/heads/${branchName}`])
        return true
      } catch (error) {
        if (error?.code === 1) return false
        throw error
      }
    },

    async createBranch(branchName, startPoint = '') {
      const args = ['checkout', '-b', branchName]
      if (startPoint) args.push(startPoint)
      await runGit(cwd, args)
    },

    async checkout(branchName) {
      await runGit(cwd, ['checkout', branchName])
    },

    async branchParent(branchName) {
      const result = await runGit(cwd, ['for-each-ref', '--format=%(upstream:short)', `refs/heads/${branchName}`])
      return result.stdout.trim().split('\n')[0] ?? ''
    },

    async setBranchParent(branchName, parentBranch) {
      await runGit(cwd, ['branch', `--set-upstream-to=${parentBranch}`, branchName])
    },
  }
}
