import assert from 'node:assert/strict'
import { mkdtemp, mkdir, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { renderLaneWorkflow } from '../scripts/render-lane-workflow.mjs'
const sourceManifest = new URL('../instances/agiletec-pilot/instance.json', import.meta.url)

async function fixture({ approved = true, frontMatter = false } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'symphony-lane-')), checkout = join(root, 'repo'), output = join(root, 'generated', 'WORKFLOW.md'), manifestPath = join(root, 'instance.json')
  const manifest = JSON.parse(await readFile(sourceManifest, 'utf8')); if (approved) manifest.runtime.status = 'approved'
  await writeFile(manifestPath, JSON.stringify(manifest)); await mkdir(join(checkout, '.symphony'), { recursive: true })
  await writeFile(join(checkout, '.symphony', 'WORKFLOW.md'), frontMatter ? '---\ntracker: {}\n---\npolicy' : '# Repository policy\n\nRead AGENTS.md.')
  return { checkout, manifestPath, output }
}
test('combines instance and repository policy', async () => { const options = await fixture(); const workflow = await renderLaneWorkflow({ ...options, repositoryName: 'agiletec' }); assert.match(workflow, /airis-symphony-pilot/); assert.match(workflow, /repo:agiletec/); assert.match(workflow, /Repository policy/) })
test('refuses blocked runtime', async () => { const options = await fixture({ approved: false }); await assert.rejects(renderLaneWorkflow({ ...options, repositoryName: 'agiletec' }), /runtime is not approved/) })
test('rejects front matter in policy', async () => { const options = await fixture({ frontMatter: true }); await assert.rejects(renderLaneWorkflow({ ...options, repositoryName: 'agiletec' }), /must not contain/) })
test('never overwrites generated workflow', async () => { const options = await fixture(); await mkdir(join(options.output, '..'), { recursive: true }); await writeFile(options.output, 'owned'); await assert.rejects(renderLaneWorkflow({ ...options, repositoryName: 'agiletec' }), /cannot create/) })
