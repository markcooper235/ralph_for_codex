import { mkdir, readdir, readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { writeRuntimeJson } from '../repositories/runtime-repository.mjs'

async function readJson(path, fallback = null) { try { return JSON.parse(await readFile(path, 'utf8')) } catch { return fallback } }

export async function rollupPrepStages(runDir) {
  const stageDir = join(runDir, 'stages')
  let files = []
  try { files = (await readdir(stageDir)).filter((file) => file.endsWith('.json')).sort() } catch { /* no stages */ }
  const entries = (await Promise.all(files.map((file) => readJson(join(stageDir, file))))).filter(Boolean)
  const stories = {}
  for (const entry of entries) {
    stories[entry.storyId] ??= {}
    stories[entry.storyId][entry.stage] = {
      status: entry.status, detail: entry.detail, artifacts: entry.artifacts,
      duration_ms: entry.duration_ms ?? 0, updated_at: entry.updated_at,
      execution_profile: entry.execution_profile ?? null,
    }
  }
  const running = entries.filter((entry) => entry.status === 'running').sort((a, b) => `${a.updated_at}${a.storyId}${a.stage}`.localeCompare(`${b.updated_at}${b.storyId}${b.stage}`)).at(-1)
  const profiled = entries.filter((entry) => entry.execution_profile != null).sort((a, b) => String(a.updated_at).localeCompare(String(b.updated_at))).at(-1)
  return {
    stories,
    metrics: {
      stage_count: entries.length,
      passed_stages: entries.filter((entry) => entry.status === 'passed').length,
      skipped_stages: entries.filter((entry) => entry.status === 'skipped').length,
      failed_stages: entries.filter((entry) => entry.status === 'failed').length,
      running_stages: entries.filter((entry) => entry.status === 'running').length,
      total_duration_ms: entries.reduce((total, entry) => total + Number(entry.duration_ms ?? 0), 0),
    },
    active_story_id: running?.storyId ?? null,
    active_stage: running?.stage ?? null,
    latest_execution_profile: profiled?.execution_profile ?? null,
  }
}

export async function recordPrepStage({ runDir, storyId, stage, status, detail = '', artifacts = [], durationMs = 0, executionProfile = null }) {
  await mkdir(join(runDir, 'stages'), { recursive: true })
  const updatedAt = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
  await writeRuntimeJson(join(runDir, 'stages', `${storyId}-${stage}.json`), { storyId, stage, status, detail, artifacts, duration_ms: Number(durationMs), updated_at: updatedAt, execution_profile: executionProfile })
  return touchPrepSummary({ runDir, phase: stage, activeStoryId: storyId, activeStage: stage, executionProfile })
}

export async function touchPrepSummary({ runDir, phase = '', activeStoryId = '', activeStage = '', executionProfile = null }) {
  const path = join(runDir, 'prepare-run.json')
  const summary = await readJson(path, { version: 1, stories: {} })
  const rollup = await rollupPrepStages(runDir)
  const now = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
  const effectivePhase = ['specify', 'generate'].includes(activeStage) ? `${activeStage}-all` : phase || summary.phase || 'running'
  await writeRuntimeJson(path, { ...summary, updated_at: now, last_progress_at: now, phase: effectivePhase, active_story_id: rollup.active_story_id ?? (activeStoryId || null), active_stage: rollup.active_stage ?? (activeStage || null), execution_profile: executionProfile ?? rollup.latest_execution_profile ?? summary.execution_profile ?? null, stories: rollup.stories, metrics: rollup.metrics })
}

export async function finalizePrepSummary(runDir, status) {
  const path = join(runDir, 'prepare-run.json')
  const summary = await readJson(path, {})
  const rollup = await rollupPrepStages(runDir)
  const now = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
  await writeRuntimeJson(path, { ...summary, status, phase: status, finished_at: now, updated_at: now, last_progress_at: now, active_story_id: null, active_stage: null, execution_profile: rollup.latest_execution_profile ?? summary.execution_profile ?? null, stories: rollup.stories, metrics: rollup.metrics })
}
