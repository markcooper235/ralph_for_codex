import { writeRuntimeJson } from '../repositories/runtime-repository.mjs'

export async function writeFallowReport({ reportPath, storyId, files = [], fallowIssues = '', deadCodeIssues = '' }) {
  const issues = []
  if (fallowIssues) issues.push({ type: 'fallow-audit', detail: fallowIssues })
  if (deadCodeIssues) issues.push({ type: 'dead-code-heuristic', detail: deadCodeIssues })
  await writeRuntimeJson(reportPath, {
    storyId,
    timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    files,
    issueCount: issues.reduce((count, issue) => count + issue.detail.split(/\r?\n/).filter(Boolean).length, 0),
    passes: issues.length === 0,
    issues,
  })
  return issues.length
}
