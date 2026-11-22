import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const moduleDir = dirname(fileURLToPath(import.meta.url))
const instanceDir = resolve(moduleDir, '..', 'instances', 'agiletec-pilot')
const manifestPath = resolve(instanceDir, 'linear-github-issues-sync.json')
const instancePath = resolve(instanceDir, 'instance.json')

function fail(message) {
  throw new Error(`[linear-github-issues-sync] ${message}`)
}

export function verifyManifest(manifest, instance) {
  if (manifest?.schemaVersion !== 1) fail('schemaVersion must be 1')
  if (manifest?.organization !== 'agiletec-inc') fail('organization must be agiletec-inc')
  if (manifest?.linear?.teamId !== 'a9356a9a-af37-4ea7-b379-a9b451214b08') {
    fail('Linear team ID must identify AIris Symphony')
  }
  if (instance?.tracker?.projectSlug !== 'airis-symphony-pilot-4d8e46efb13b') {
    fail('instance tracker must identify AIris Symphony Pilot')
  }
  if (manifest?.sync?.direction !== 'github_to_linear') {
    fail('sync direction must remain GitHub to Linear')
  }
  for (const field of ['futureIssues', 'historicalIssues']) {
    if (!String(manifest?.sync?.[field] ?? '').startsWith('pending_')) {
      fail(`${field} must remain pending until live Linear read-back proves activation`)
    }
  }
  const repositories = manifest?.repositories
  if (!Array.isArray(repositories) || repositories.length === 0) {
    fail('repositories must be a non-empty array')
  }
  if (new Set(repositories).size !== repositories.length) fail('repositories must be unique')
  if ([...repositories].sort().join('\n') !== repositories.join('\n')) {
    fail('repositories must be sorted')
  }
  for (const repository of repositories) {
    if (typeof repository !== 'string' || !/^[A-Za-z0-9_.-]+$/.test(repository)) {
      fail(`invalid repository name: ${repository}`)
    }
  }
  return manifest
}

export function verifyLiveRepositories(manifest, liveRepositories) {
  const expected = manifest.repositories
  const actual = liveRepositories
    .filter((repository) => !repository.archived && repository.has_issues)
    .map((repository) => repository.name)
    .sort()
  const missing = actual.filter((name) => !expected.includes(name))
  const stale = expected.filter((name) => !actual.includes(name))
  if (missing.length || stale.length) {
    fail(`repository drift: missing=[${missing.join(',')}], stale=[${stale.join(',')}]`)
  }
}

export function readManifest() {
  return verifyManifest(
    JSON.parse(readFileSync(manifestPath, 'utf8')),
    JSON.parse(readFileSync(instancePath, 'utf8'))
  )
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const manifest = readManifest()
  if (process.argv.includes('--live')) {
    const pages = JSON.parse(
      execFileSync(
        'gh',
        [
          'api',
          '--paginate',
          '--slurp',
          `orgs/${manifest.organization}/repos?per_page=100&type=all`,
        ],
        { encoding: 'utf8' }
      )
    )
    verifyLiveRepositories(manifest, pages.flat())
  }
  console.info(
    `[linear-github-issues-sync] OK (${manifest.repositories.length} repositories${process.argv.includes('--live') ? ', live' : ''})`
  )
}
