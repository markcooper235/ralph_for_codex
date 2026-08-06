import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

export async function buildProjectCommandMap(workspaceRoot) {
  let packageJson = {}
  try {
    packageJson = JSON.parse(await readFile(join(workspaceRoot, 'package.json'), 'utf8'))
  } catch {
    // Projects without package.json simply have no npm command mappings.
  }
  const scripts = packageJson.scripts ?? {}
  return Object.fromEntries(['typecheck', 'lint', 'test', 'build'].map((kind) => [
    kind,
    typeof scripts[kind] === 'string' && scripts[kind] ? `npm run ${kind}` : null,
  ]))
}
