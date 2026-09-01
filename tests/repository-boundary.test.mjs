import assert from 'node:assert/strict'
import { mkdtemp, mkdir, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { auditRepositoryBoundary } from '../scripts/audit-repository-boundary.mjs'

const manifestPath = new URL('../instances/agiletec-pilot/instance.json', import.meta.url)

async function checkout() {
  const root = await mkdtemp(join(tmpdir(), 'symphony-boundary-'))
  await mkdir(join(root, '.symphony'), { recursive: true })
  await writeFile(join(root, '.symphony', 'WORKFLOW.md'), '# Policy\n\nRead AGENTS.md.\n')
  return root
}

test('accepts a repository that owns policy but no instance configuration', async () => {
  const root = await checkout()
  await auditRepositoryBoundary({ manifestPath, repositoryName: 'agiletec', checkout: root })
})

test('reports every remaining legacy authority in one deterministic failure', async () => {
  const root = await checkout()
  await writeFile(
    join(root, 'WORKFLOW.md'),
    'airis-symphony-pilot-4d8e46efb13b\nsymphony-pilot\nrepo:agiletec\n',
  )
  await mkdir(join(root, 'deployment', 'symphony'), { recursive: true })
  await writeFile(join(root, 'deployment', 'symphony', 'upstream.json'), '{}')
  await writeFile(join(root, 'deployment', 'symphony', 'repo-lanes.json'), '{}')

  await assert.rejects(
    auditRepositoryBoundary({ manifestPath, repositoryName: 'agiletec', checkout: root }),
    (error) => {
      assert.match(error.message, /duplicates instance authority: airis-symphony-pilot/)
      assert.match(error.message, /duplicates instance authority: symphony-pilot/)
      assert.match(error.message, /duplicates instance authority: repo:agiletec/)
      assert.match(error.message, /legacy consumer-owned instance authority remains: deployment\/symphony\/upstream.json/)
      assert.match(error.message, /legacy consumer-owned instance authority remains: deployment\/symphony\/repo-lanes.json/)
      return true
    },
  )
})

test('rejects a missing repository policy', async () => {
  const root = await mkdtemp(join(tmpdir(), 'symphony-boundary-'))
  await assert.rejects(
    auditRepositoryBoundary({ manifestPath, repositoryName: 'agiletec', checkout: root }),
    /missing repository workflow policy/,
  )
})
