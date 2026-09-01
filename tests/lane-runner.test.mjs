import assert from 'node:assert/strict'
import { mkdtemp, mkdir, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'

const runner = new URL('../scripts/run-instance-lane.sh', import.meta.url).pathname
const manifest = new URL('../instances/agiletec-pilot/instance.json', import.meta.url).pathname

test('runner checks host-owned credentials before creating runtime artifacts', async () => {
  const root = await mkdtemp(join(tmpdir(), 'symphony-runner-'))
  const result = spawnSync('sh', [runner, manifest, 'agiletec', root, '/missing', root, root], {
    encoding: 'utf8',
    env: {},
  })
  assert.equal(result.status, 78)
  assert.match(result.stderr, /missing host environment variable: LINEAR_API_KEY/)
})

test('runner fails closed on repository drift before rendering a workflow', async () => {
  const root = await mkdtemp(join(tmpdir(), 'symphony-runner-'))
  const checkout = join(root, 'repo')
  const config = join(root, 'config')
  const logs = join(root, 'logs')
  const binary = join(root, 'symphony')
  await mkdir(checkout)
  await mkdir(config)
  await mkdir(logs)
  await writeFile(binary, '#!/bin/sh\nexit 99\n', { mode: 0o755 })
  const result = spawnSync(
    'sh',
    [runner, manifest, 'agiletec', checkout, binary, config, logs],
    {
      encoding: 'utf8',
      env: {
        PATH: process.env.PATH,
        LINEAR_API_KEY: 'present-for-contract-test',
        SYMPHONY_WORKSPACE_ROOT: join(root, 'workspaces'),
        SYMPHONY_REVIEWER_LOGIN: 'reviewer',
      },
    },
  )
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /missing repository workflow policy/)
})
