import { inferChecksFromText } from '../application/check-inference.mjs'

const text = process.argv.slice(2).join(' ')
if (!text) {
  console.error('Usage: infer-checks.mjs <text>')
  process.exitCode = 2
} else {
  process.stdout.write(`${JSON.stringify(inferChecksFromText(text))}\n`)
}
