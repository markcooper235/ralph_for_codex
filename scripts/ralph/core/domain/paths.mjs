const BLOCKED_SEGMENTS = /(^|\/)(node_modules|\.next|coverage|dist|build|vendor|tmp|temp|output|playwright-report|test-results|\.cache|scripts\/ralph\/runtime|dist-docs)(\/|$)/
const DOC_SEGMENTS = /(^|\/)(docs|doc)(\/|$)/
const GENERATED_SUFFIX = /\.(log|tmp|temp|cache)$/

export function sanitizePaths(paths = []) {
  return [...new Set(paths.filter((value) => (
    typeof value === 'string'
    && !BLOCKED_SEGMENTS.test(value)
    && !DOC_SEGMENTS.test(value)
    && !GENERATED_SUFFIX.test(value)
  )))]
}

export function extractCheckFile(check = '') {
  let match = check.match(/test\s+-[fed]\s+([^\s]+)/)
  if (match) return match[1]
  match = check.match(/\[\s+-[fed]\s+([^\s|]+)/)
  if (match) return match[1]
  if (/^(grep|cat|wc)\s/.test(check)) return check.trim().split(/\s+/).at(-1)
  return ''
}
