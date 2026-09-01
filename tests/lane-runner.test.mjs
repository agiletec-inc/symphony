import assert from 'node:assert/strict'
import { mkdtemp, mkdir, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'
const runner = new URL('../scripts/run-instance-lane.sh', import.meta.url).pathname, manifest = new URL('../instances/agiletec-pilot/instance.json', import.meta.url).pathname
test('checks host credentials first', async () => { const root = await mkdtemp(join(tmpdir(), 'symphony-runner-')); const result = spawnSync('sh', [runner, manifest, 'agiletec', root, '/missing', root, root], { encoding: 'utf8', env: {} }); assert.equal(result.status, 78); assert.match(result.stderr, /LINEAR_API_KEY/) })
test('fails on repository drift', async () => { const root = await mkdtemp(join(tmpdir(), 'symphony-runner-')), checkout = join(root, 'repo'), config = join(root, 'config'), logs = join(root, 'logs'), binary = join(root, 'symphony'); await mkdir(checkout); await mkdir(config); await mkdir(logs); await writeFile(binary, '#!/bin/sh\nexit 99\n', { mode: 0o755 }); const result = spawnSync('sh', [runner, manifest, 'agiletec', checkout, binary, config, logs], { encoding: 'utf8', env: { PATH: process.env.PATH, LINEAR_API_KEY: 'test', SYMPHONY_WORKSPACE_ROOT: join(root, 'workspaces'), SYMPHONY_REVIEWER_LOGIN: 'reviewer' } }); assert.match(result.stderr, /missing repository workflow policy/) })
