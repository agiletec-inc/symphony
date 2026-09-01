import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'
import { verifyInstance } from '../scripts/verify-instance.mjs'
import { verifyManifest } from '../scripts/verify-linear-github-issues-sync.mjs'
const manifestPath = new URL('../instances/agiletec-pilot/instance.json', import.meta.url)
const load = async () => JSON.parse(await readFile(manifestPath, 'utf8'))

test('instance has one cross-repository authority', async () => {
  const instance = verifyInstance(await load())
  assert.equal(instance.runtime.repository, 'https://github.com/agiletec-inc/symphony.git')
  assert.equal(instance.repositories.length, 1)
})
test('runtime fails closed', async () => { const instance = await load(); assert.throws(() => verifyInstance(instance, { runtime: true }), /blocked_dependency_advisories/) })
test('duplicate lane is rejected', async () => { const instance = await load(); instance.repositories.push({ ...instance.repositories[0], name: 'duplicate' }); assert.throws(() => verifyInstance(instance), /duplicate repository lane repository/) })
test('capacity cannot expand', async () => { const instance = await load(); instance.capacity.maxConcurrentAgents = 2; assert.throws(() => verifyInstance(instance), /must remain 1/) })
test('policy cannot escape checkout', async () => { const instance = await load(); instance.repositories[0].workflowPath = '../WORKFLOW.md'; assert.throws(() => verifyInstance(instance), /must stay inside/) })
test('clone URL matches identity', async () => { const instance = await load(); instance.repositories[0].cloneUrl = 'https://example.com/x'; assert.throws(() => verifyInstance(instance), /must match/) })
test('GitHub sync inventory reads the project slug from the instance authority', async () => {
  const instance = await load()
  const inventory = JSON.parse(await readFile(new URL('../instances/agiletec-pilot/linear-github-issues-sync.json', import.meta.url), 'utf8'))
  assert.equal(inventory.linear.projectSlug, undefined)
  assert.equal(verifyManifest(inventory, instance), inventory)
})
test('artifact build and synthetic test consume the instance manifest', async () => {
  for (const name of ['build-official.sh', 'test-synthetic-config.sh']) {
    const source = await readFile(new URL(`../instances/agiletec-pilot/${name}`, import.meta.url), 'utf8')
    assert.match(source, /instance\.json/)
    assert.doesNotMatch(source, /upstream\.json/)
  }
})
