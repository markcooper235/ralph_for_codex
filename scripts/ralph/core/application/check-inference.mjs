export function inferChecksFromText(text = '') {
  const checks = []
  if (/(^|[^\p{L}\d_])(typecheck|tsc|type check|type-check)($|[^\p{L}\d_])/iu.test(text)) checks.push('npm run typecheck')
  if (/(^|[^\p{L}\d_])(test|tests|jest|vitest|pytest|go test)($|[^\p{L}\d_])/iu.test(text)) checks.push('npm test')
  if (/(^|[^\p{L}\d_])(lint|eslint)($|[^\p{L}\d_])/iu.test(text)) checks.push('npm run lint')
  if (/(^|[^\p{L}\d_])build($|[^\p{L}\d_])/iu.test(text)) checks.push('npm run build')
  if (/verify in browser|playwright|cypress|verification/i.test(text)) checks.push('echo browser verification required')
  return [...new Set(checks.length > 0 ? checks : ['npm run typecheck'])]
}
