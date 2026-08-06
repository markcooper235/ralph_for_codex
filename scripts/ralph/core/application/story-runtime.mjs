import { writeRuntimeJson } from '../repositories/runtime-repository.mjs'

export async function writeStoryRuntimeManifest(manifestPath, values) {
  const [
    storyId, title, storyFile, runtimeDir, logDir, phase, startedAt, updatedAt,
    lastProgressAt, currentTaskId, currentCheck, lastCompletedMilestone,
    failedTaskId, failureBundlePath, failureSummaryPath, attempt,
    currentCheckIndex, currentCheckTotal, elapsedMs, executionProfile,
  ] = values
  await writeRuntimeJson(manifestPath, {
    story_id: storyId,
    title,
    story_file: storyFile,
    runtime_dir: runtimeDir,
    log_dir: logDir,
    phase,
    started_at: startedAt || null,
    updated_at: updatedAt,
    last_progress_at: lastProgressAt || null,
    elapsed_ms: Number(elapsedMs),
    attempt: Number(attempt),
    current_task_id: currentTaskId || null,
    current_check: currentCheck || null,
    current_check_index: Number(currentCheckIndex) > 0 ? Number(currentCheckIndex) : null,
    current_check_total: Number(currentCheckTotal) > 0 ? Number(currentCheckTotal) : null,
    last_completed_milestone: lastCompletedMilestone || null,
    execution_profile: executionProfile === 'null' ? null : JSON.parse(executionProfile),
    failed_task_id: failedTaskId || null,
    failure_bundle_path: failureBundlePath || null,
    failure_summary_path: failureSummaryPath || null,
  })
}
