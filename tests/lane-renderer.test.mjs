import assert from 'node:assert/strict'
import { mkdtemp, mkdir, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { renderLaneWorkflow } from '../scripts/render-lane-workflow.mjs'

const sourceManifest = new URL('../instances/agiletec-pilot/instance.json', import.meta.url)

async function fixture({ approved = true, frontMatter = false } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'symphony-lane-'))
  const checkout = join(root, 'repo')
  const output = join(root, 'generated', 'WORKFLOW.md')
  const manifestPath = join(root, 'instance.json')
  const manifest = JSON.parse(await readFile(sourceManifest, 'utf8'))
  if (approved) manifest.runtime.status = 'approved'
  await writeFile(manifestPath, JSON.stringify(manifest))
  await mkdir(join(checkout, '.symphony'), { recursive: true })
  await writeFile(
    join(checkout, '.symphony', 'WORKFLOW.md'),
    frontMatter ? '---\ntracker: {}\n---\npolicy' : '# Repository policy\n\nRead AGENTS.md.',
  )
  return { checkout, manifestPath, output }
}

test('combines instance authority with repository-owned prompt policy', async () => {
  const options = await fixture()
  await renderLaneWorkflow({ ...options, repositoryName: 'agiletec' })
  const workflow = await readFile(options.output, 'utf8')
  assert.match(workflow, /project_slug: "airis-symphony-pilot-4d8e46efb13b"/)
  assert.match(workflow, /- "symphony-pilot"\n    - "repo:agiletec"/)
  assert.match(workflow, /max_concurrent_agents: 1/)
  assert.match(workflow, /# Repository policy\n\nRead AGENTS\.md\./)
})

test('refuses to render a blocked runtime', async () => {
  const options = await fixture({ approved: false })
  await assert.rejects(
    renderLaneWorkflow({ ...options, repositoryName: 'agiletec' }),
    /runtime is not approved: blocked_dependency_advisories/,
  )
})

test('rejects instance-owned configuration in repository policy', async () => {
  const options = await fixture({ frontMatter: true })
  await assert.rejects(
    renderLaneWorkflow({ ...options, repositoryName: 'agiletec' }),
    /must not contain instance-owned YAML front matter/,
  )
})

test('never overwrites an existing generated workflow', async () => {
  const options = await fixture()
  await mkdir(join(options.output, '..'), { recursive: true })
  await writeFile(options.output, 'owned elsewhere')
  await assert.rejects(
    renderLaneWorkflow({ ...options, repositoryName: 'agiletec' }),
    /cannot create generated workflow/,
  )
})
