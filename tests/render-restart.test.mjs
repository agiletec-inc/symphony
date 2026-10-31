import assert from 'node:assert/strict'
import { mkdtemp, mkdir, readFile, readlink, symlink, unlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { renderLaneWorkflow } from '../scripts/render-lane-workflow.mjs'

const sourceManifest = new URL('../instances/agiletec-pilot/instance.json', import.meta.url)

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'symphony-render-restart-'))
  const checkout = join(root, 'repo')
  const output = join(root, 'config', 'agiletec.WORKFLOW.md')
  const manifestPath = join(root, 'instance.json')
  const manifest = JSON.parse(await readFile(sourceManifest, 'utf8'))

  manifest.runtime.status = 'approved'
  await writeFile(manifestPath, JSON.stringify(manifest))
  await mkdir(join(checkout, '.symphony'), { recursive: true })
  await writeFile(join(checkout, '.symphony', 'WORKFLOW.md'), '# Repository policy\n\nRead AGENTS.md.')
  return { checkout, manifestPath, output }
}

const render = (options) => renderLaneWorkflow({ ...options, repositoryName: 'agiletec' })

test('reuses identical generated workflow on restart without changing bytes', async () => {
  const options = await fixture()
  const first = await render(options)
  const before = await readFile(options.output)

  const second = await render(options)

  assert.equal(second, first)
  assert.deepEqual(await readFile(options.output), before)
})

test('rejects different existing output while preserving its bytes', async () => {
  const options = await fixture()
  await mkdir(join(options.output, '..'), { recursive: true })
  const original = Buffer.from('operator-owned output\n')
  await writeFile(options.output, original)

  await assert.rejects(render(options), /cannot create generated workflow/)
  assert.deepEqual(await readFile(options.output), original)
})

test('rejects output symlink, including same-content target, without changing target', async () => {
  const options = await fixture()
  const target = join(options.output, '..', 'target.WORKFLOW.md')
  await mkdir(join(options.output, '..'), { recursive: true })
  await render(options)
  const original = await readFile(options.output)
  await unlink(options.output)
  await writeFile(target, original)
  await symlink(target, options.output)

  await assert.rejects(render(options), /cannot create generated workflow/)
  assert.deepEqual(await readFile(target), original)
  assert.equal(await readlink(options.output), target)
})
