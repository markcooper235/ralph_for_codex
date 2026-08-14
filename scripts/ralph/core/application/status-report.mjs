import { access, readdir, readFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { readBacklog } from '../repositories/backlog-repository.mjs'

const execFileAsync = promisify(execFile)

async function exists(path) {
  try { await access(path); return true } catch { return false }
}

async function json(path, fallback = null) {
  try { return JSON.parse(await readFile(path, 'utf8')) } catch { return fallback }
}

async function latestManifest(root, filename, suffix = '') {
  if (!(await exists(root))) return ''
  const names = (await readdir(root, { withFileTypes: true }))
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .filter((name) => !suffix || name.includes(suffix))
    .sort()
    .reverse()
  for (const name of names) {
    const path = join(root, name, filename)
    if (await exists(path)) return path
  }
  return ''
}

async function git(workspaceRoot, args) {
  try {
    const { stdout } = await execFileAsync('git', ['-C', workspaceRoot, ...args], { encoding: 'utf8' })
    return stdout.trim()
  } catch { return '' }
}

function storyReadiness(story, workspaceRoot) {
  if (['done', 'abandoned', 'active'].includes(story.status)) return story.status
  if (!story.story_path) return 'stub'
  return story._story_file_exists ? 'ready' : story._spec_exists ? 'specked' : 'stub'
}

function profileLine(profile) {
  if (!profile) return ''
  const value = `Execution profile: harness=${profile.harness ?? 'unknown'}`
  return [
    value,
    profile.model ? `model=${profile.model}` : '',
    profile.agent ? `agent=${profile.agent}` : '',
    profile.composite_profile ? `composite=${profile.composite_profile}` : '',
    profile.execution_tier ? `tier=${profile.execution_tier}` : '',
    `composites=${profile.composites_enabled ? 'on' : 'off'}`,
    profile.codex_profile ? `codex-profile=${profile.codex_profile}` : '',
    profile.harness_source ? `harness-source=${profile.harness_source}` : '',
    profile.model_source ? `model-source=${profile.model_source}` : '',
    profile.agent_source ? `agent-source=${profile.agent_source}` : '',
  ].filter(Boolean).join(' ')
}

function prepMetrics(prep) {
  const stages = Object.values(prep?.stories ?? {}).flatMap((story) => Object.values(story ?? {}))
  const metrics = prep?.metrics ?? {}
  return {
    stories: Object.keys(prep?.stories ?? {}).length,
    passed: metrics.passed_stages ?? stages.filter((stage) => stage?.status === 'passed').length,
    failed: metrics.failed_stages ?? stages.filter((stage) => stage?.status === 'failed').length,
    skipped: metrics.skipped_stages ?? stages.filter((stage) => stage?.status === 'skipped').length,
    duration: metrics.total_duration_ms ?? 0,
  }
}

function prepDetailLines(prep, limit) {
  return Object.entries(prep?.stories ?? {})
    .sort(([a], [b]) => a.localeCompare(b))
    .slice(0, limit)
    .flatMap(([storyId, stages]) => Object.entries(stages ?? {})
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([stageId, stage]) => {
        const profile = stage?.execution_profile
        const profileText = profile
          ? ` [harness=${profile.harness ?? 'unknown'}${profile.model ? ` model=${profile.model}` : ''}${profile.agent ? ` agent=${profile.agent}` : ''}${profile.composite_profile ? ` composite=${profile.composite_profile}` : ''}${profile.execution_tier ? ` tier=${profile.execution_tier}` : ''}${profile.composites_enabled ? ' composites=on' : ' composites=off'}]`
          : ''
        return `Prep detail ${storyId} ${stageId}: ${stage?.status ?? 'unknown'}${stage?.detail ? ` - ${stage.detail}` : ''} (duration-ms=${stage?.duration_ms ?? 0}, updated=${stage?.updated_at ?? 'unknown'})${profileText}`
      }))
}

function prepStoryLines(prep, limit) {
  return Object.entries(prep?.stories ?? {})
    .sort(([a], [b]) => a.localeCompare(b))
    .slice(0, limit)
    .map(([storyId, stages]) => {
      const values = Object.entries(stages ?? {}).sort(([a], [b]) => a.localeCompare(b))
      const summary = values.map(([stage, value]) => `${stage}=${value?.status ?? 'unknown'}`).join(', ')
      return `Prep story ${storyId}: ${summary || '(no stages recorded)'}`
    })
}

function prepLines(prep, prepDetails, prepStoryLimit) {
  if (!prep) return []
  const metrics = prepMetrics(prep)
  const lines = [
    `Prep: ${prep.status ?? 'running'} (${prep.mode ?? 'prep'}, phase=${prep.phase ?? 'unknown'}, stories=${metrics.stories}, passed-stages=${metrics.passed}, failed-stages=${metrics.failed}, skipped-stages=${metrics.skipped}, duration-ms=${metrics.duration})`,
  ]
  if (prep.active_story_id || prep.active_stage) lines.push(`Prep active: story=${prep.active_story_id ?? 'none'} stage=${prep.active_stage ?? 'none'}`)
  if (prep.updated_at ?? prep.started_at) lines.push(`Prep updated: ${prep.updated_at ?? prep.started_at}`)
  if (prep.last_progress_at && prep.last_progress_at !== (prep.updated_at ?? prep.started_at)) lines.push(`Prep progress: ${prep.last_progress_at}`)
  lines.push(`Prep journal: ${prep.path}`)
  lines.push(...prepStoryLines(prep, prepStoryLimit))
  if (prepDetails) lines.push(...prepDetailLines(prep, prepStoryLimit))
  return lines
}

export async function buildStatusReport({ workspaceRoot, ralphRoot, activeSprint = '', prepDetails = false, prepStoryLimit = 5, loopState = 'stopped' }) {
  const storiesPath = activeSprint ? join(ralphRoot, 'sprints', activeSprint, 'stories.json') : ''
  const backlog = storiesPath ? await json(storiesPath) : null
  const prepRoot = join(ralphRoot, 'runtime', 'prep-runs')
  const sprintRunsRoot = join(ralphRoot, 'runtime', 'sprint-runs')
  const prepPath = activeSprint
    ? await latestManifest(prepRoot, 'prepare-run.json', `-${activeSprint}-`)
    : await latestManifest(prepRoot, 'prepare-run.json')
  const sprintManifestPath = activeSprint ? await latestManifest(sprintRunsRoot, 'sprint-run.json', `-${activeSprint}`) : ''
  const prep = prepPath ? await json(prepPath) : null
  const sprintManifest = sprintManifestPath ? await json(sprintManifestPath) : null
  const activeId = backlog?.activeStoryId ?? ''
  const activeStory = backlog?.stories?.find((story) => String(story.id) === String(activeId))
  const activeStoryPath = activeStory?.story_path ? resolve(workspaceRoot, activeStory.story_path) : ''
  const storyFile = activeStoryPath ? await json(activeStoryPath) : null
  const runDir = sprintManifest?.run_dir ?? ''
  const storyManifestPath = activeId && runDir ? join(runDir, 'stories', activeId, 'story-summary.json') : ''
  const storyManifest = storyManifestPath ? await json(storyManifestPath) : null
  const branch = await git(workspaceRoot, ['branch', '--show-current'])
  const status = await git(workspaceRoot, ['status', '--short'])
  const stories = await Promise.all((backlog?.stories ?? []).map(async (story) => ({
    ...story,
    _story_file_exists: story.story_path ? await exists(resolve(workspaceRoot, story.story_path)) : false,
    _spec_exists: story.story_path ? await exists(join(resolve(workspaceRoot, story.story_path), '..', '.specify', 'spec.md')) : false,
  })))
  const allDone = stories.length > 0 && stories.every((story) => ['done', 'abandoned'].includes(story.status))
  const next = stories
    .filter((story) => ['ready', 'planned'].includes(story.status))
    .sort((a, b) => (a.priority ?? 0) - (b.priority ?? 0) || String(a.id).localeCompare(String(b.id)))
    .find((story) => (story.depends_on ?? []).every((id) => stories.find((candidate) => candidate.id === id)?.status === 'done'))
  const prepStories = Object.entries(prep?.stories ?? {}).sort(([a], [b]) => a.localeCompare(b)).slice(0, prepStoryLimit)
  return {
    activeSprint,
    sprintBranch: activeSprint ? `ralph/sprint/${activeSprint}` : '',
    currentBranch: branch,
    worktree: status ? 'dirty' : 'clean',
    activeStory: activeStory ? { ...activeStory, fileStatus: storyFile?.status ?? '' } : null,
    nextStory: next ?? null,
    stories,
    allDone,
    sprintManifest,
    prep: prep ? { ...prep, path: prepPath, entries: prepStories, details: prepDetails, storyLimit: prepStoryLimit } : null,
    storyManifest,
    latestCommit: await git(workspaceRoot, ['log', '--oneline', '--max-count=1', '--grep=^\\(feat\\|fix\\): \\[US-']),
    loopState,
  }
}

export function renderStatusReport(report) {
  const lines = []
  if (!report.activeSprint) {
    lines.push('Active sprint: (none)', `Loop: ${report.loopState}`, `Worktree: ${report.worktree}`)
    if (report.prep) lines.push(`Prep: ${report.prep.status ?? 'running'} (${report.prep.mode ?? 'prep'})`, `Prep journal: ${report.prep.path}`)
    lines.push('Next action: run ./scripts/ralph/ralph-sprint.sh use <sprint-name>.')
    return lines.join('\n')
  }
  lines.push(`Active sprint: ${report.activeSprint}`, `Sprint branch: ${report.sprintBranch}`, `Current branch: ${report.currentBranch || '(detached)'}`, `Loop: ${report.loopState}${report.sprintManifest?.phase ? ` (last-phase=${report.sprintManifest.phase})` : ''}`, `Worktree: ${report.worktree}`)
  if (report.sprintManifest) lines.push(`Sprint runtime: phase=${report.sprintManifest.phase ?? 'unknown'}${report.sprintManifest.active_story_id ? ` active-story=${report.sprintManifest.active_story_id}` : ''}`)
  if (report.prep) lines.push(...prepLines(report.prep, report.prep.details, report.prep.storyLimit ?? 5))
  if (report.activeStory) {
    lines.push(`Active story: ${report.activeStory.id} (P${report.activeStory.priority ?? 0} E${report.activeStory.effort ?? 0}) - ${report.activeStory.title}`)
    lines.push(`Story status: ${report.activeStory.fileStatus || report.activeStory.status}`)
    if (report.storyManifest) lines.push(`Story runtime: phase=${report.storyManifest.phase ?? 'unknown'}${report.storyManifest.current_task_id ? ` task=${report.storyManifest.current_task_id}` : ''}`)
    if (report.storyManifest?.execution_profile) lines.push(profileLine(report.storyManifest.execution_profile))
  } else lines.push('Active story: (none)')
  lines.push(report.nextStory ? `Next eligible story: ${report.nextStory.id} (P${report.nextStory.priority ?? 0} E${report.nextStory.effort ?? 0}) - ${report.nextStory.title}` : 'Next eligible story: (none)')
  lines.push('', '--- ID        PRI    EFF    READY      STATUS       TITLE', '--- ---------- ------ ------ ---------- ------------ -----')
  for (const story of report.stories.sort((a, b) => (a.priority ?? 0) - (b.priority ?? 0))) {
    const marker = story.id === report.activeStory?.id ? '-> ' : '   '
    lines.push(`${marker}${String(story.id).padEnd(10)} ${String(story.priority ?? 0).padEnd(6)} ${String(story.effort ?? 0).padEnd(6)} ${storyReadiness(story, '').padEnd(10)} ${String(story.status ?? '').padEnd(12)} ${story.title ?? ''}`)
  }
  if (report.latestCommit) lines.push(`Latest story commit: ${report.latestCommit}`)
  const action = report.allDone
    ? (report.loopState === 'running' ? 'Next action: wait for Ralph to finish closeout.' : 'Next action: run ./scripts/ralph/ralph-sprint-commit.sh to close out the completed sprint.')
    : report.loopState === 'running' ? 'Next action: Ralph is running; monitor the active story.'
      : report.activeStory?.status === 'active' ? 'Next action: run ./scripts/ralph/ralph-story-run.sh to continue the active story.'
        : 'Next action: run ./scripts/ralph/ralph-story.sh start-next && ./scripts/ralph/ralph-story-run.sh'
  lines.push(action)
  return lines.join('\n')
}
