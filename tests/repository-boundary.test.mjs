import assert from 'node:assert/strict'
import { mkdtemp, mkdir, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { auditRepositoryBoundary } from '../scripts/audit-repository-boundary.mjs'
const manifestPath = new URL('../instances/agiletec-pilot/instance.json', import.meta.url)
async function checkout() { const root = await mkdtemp(join(tmpdir(), 'symphony-boundary-')); await mkdir(join(root, '.symphony'), { recursive: true }); await writeFile(join(root, '.symphony', 'WORKFLOW.md'), '# Policy\n'); return root }
test('accepts repository-owned policy', async () => { await auditRepositoryBoundary({ manifestPath, repositoryName: 'agiletec', checkout: await checkout() }) })
test('reports legacy authorities', async () => { const root = await checkout(); await writeFile(join(root, 'WORKFLOW.md'), 'airis-symphony-pilot-4d8e46efb13b\nsymphony-pilot\nrepo:agiletec'); await mkdir(join(root, 'deployment', 'symphony'), { recursive: true }); await writeFile(join(root, 'deployment', 'symphony', 'upstream.json'), '{}'); await assert.rejects(auditRepositoryBoundary({ manifestPath, repositoryName: 'agiletec', checkout: root }), (error) => { assert.match(error.message, /duplicates instance authority/); assert.match(error.message, /legacy consumer-owned/); return true }) })
test('rejects missing policy', async () => { const root = await mkdtemp(join(tmpdir(), 'symphony-boundary-')); await assert.rejects(auditRepositoryBoundary({ manifestPath, repositoryName: 'agiletec', checkout: root }), /missing repository workflow policy/) })
