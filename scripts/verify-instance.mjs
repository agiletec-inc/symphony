import { readFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'

const fail = (message) => {
  throw new Error(`[symphony-instance] ${message}`)
}

const nonBlank = (value, field) => {
  if (typeof value !== 'string' || value.trim() === '') fail(`${field} must be a non-blank string`)
}

export function verifyInstance(instance, { runtime = false } = {}) {
  if (instance?.schemaVersion !== 1) fail('schemaVersion must be 1')
  nonBlank(instance.instanceId, 'instanceId')

  if (instance.tracker?.kind !== 'linear') fail('tracker.kind must be linear')
  nonBlank(instance.tracker.projectSlug, 'tracker.projectSlug')
  nonBlank(instance.tracker.commonRequiredLabel, 'tracker.commonRequiredLabel')

  nonBlank(instance.runtime?.repository, 'runtime.repository')
  nonBlank(instance.runtime?.upstreamRepository, 'runtime.upstreamRepository')
  if (!/^[0-9a-f]{40}$/.test(instance.runtime?.commit ?? '')) {
    fail('runtime.commit must be a full Git commit SHA')
  }
  if (!/^[^@\s]+@sha256:[0-9a-f]{64}$/.test(instance.runtime?.buildImage ?? '')) {
    fail('runtime.buildImage must use a sha256 digest')
  }
  nonBlank(instance.runtime.status, 'runtime.status')
  if (runtime && instance.runtime.status !== 'approved') {
    fail(`runtime is not approved: ${instance.runtime.status}`)
  }

  if (instance.capacity?.maxConcurrentAgents !== 1) {
    fail('capacity.maxConcurrentAgents must remain 1 during the pilot')
  }
  if (!Array.isArray(instance.repositories) || instance.repositories.length === 0) {
    fail('repositories must contain at least one lane')
  }

  const names = new Set()
  const repositories = new Set()
  const labels = new Set()
  for (const [index, lane] of instance.repositories.entries()) {
    const field = `repositories[${index}]`
    nonBlank(lane?.name, `${field}.name`)
    nonBlank(lane?.repository, `${field}.repository`)
    nonBlank(lane?.cloneUrl, `${field}.cloneUrl`)
    nonBlank(lane?.requiredLabel, `${field}.requiredLabel`)
    nonBlank(lane?.workflowPath, `${field}.workflowPath`)
    if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(lane.repository)) {
      fail(`${field}.repository must be an owner/name GitHub identity`)
    }
    if (lane.cloneUrl !== `https://github.com/${lane.repository}.git`) {
      fail(`${field}.cloneUrl must match repository identity`)
    }
    const workflowSegments = lane.workflowPath.split('/')
    if (lane.workflowPath.startsWith('/') || workflowSegments.includes('..')) {
      fail(`${field}.workflowPath must stay inside the repository`)
    }
    if (lane.enabled !== true && lane.enabled !== false) fail(`${field}.enabled must be boolean`)
    if (lane.requiredLabel === instance.tracker.commonRequiredLabel) {
      fail(`${field}.requiredLabel must be repository-specific`)
    }
    for (const [set, value, name] of [
      [names, lane.name, 'name'],
      [repositories, lane.repository, 'repository'],
      [labels, lane.requiredLabel, 'requiredLabel'],
    ]) {
      if (set.has(value)) fail(`duplicate repository lane ${name}: ${value}`)
      set.add(value)
    }
  }

  return instance
}

export async function readAndVerifyInstance(file, options) {
  let instance
  try {
    instance = JSON.parse(await readFile(file, 'utf8'))
  } catch (error) {
    fail(`cannot read manifest: ${error.message}`)
  }
  return verifyInstance(instance, options)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2)
  const runtime = args.includes('--runtime')
  const file = args.find((arg) => arg !== '--runtime')
  if (!file) fail('usage: verify-instance.mjs <instance.json> [--runtime]')
  await readAndVerifyInstance(file, { runtime })
  console.log(`[symphony-instance] OK (${runtime ? 'runtime' : 'static'} validation)`)
}
