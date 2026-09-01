import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'
import { verifyInstance } from '../scripts/verify-instance.mjs'

const manifestPath = new URL('../instances/agiletec-pilot/instance.json', import.meta.url)
const load = async () => JSON.parse(await readFile(manifestPath, 'utf8'))

test('the AgileTech instance has one machine-readable cross-repository authority', async () => {
  const instance = verifyInstance(await load())
  assert.equal(instance.runtime.repository, 'https://github.com/agiletec-inc/symphony.git')
  assert.equal(instance.repositories.length, 1)
  assert.deepEqual(instance.repositories[0], {
    name: 'agiletec',
    repository: 'agiletec-inc/agiletec',
    cloneUrl: 'https://github.com/agiletec-inc/agiletec.git',
    requiredLabel: 'repo:agiletec',
    workflowPath: '.symphony/WORKFLOW.md',
    enabled: true,
  })
})

test('runtime validation fails closed while dependency advisories are unresolved', async () => {
  const instance = await load()
  assert.throws(
    () => verifyInstance(instance, { runtime: true }),
    /runtime is not approved: blocked_dependency_advisories/,
  )
})

test('duplicate lane authority is rejected', async () => {
  const instance = await load()
  instance.repositories.push({ ...instance.repositories[0], name: 'duplicate' })
  assert.throws(() => verifyInstance(instance), /duplicate repository lane repository/)
})

test('repository labels cannot collapse into the instance-wide label', async () => {
  const instance = await load()
  instance.repositories[0].requiredLabel = instance.tracker.commonRequiredLabel
  assert.throws(() => verifyInstance(instance), /must be repository-specific/)
})

test('pilot capacity cannot expand accidentally', async () => {
  const instance = await load()
  instance.capacity.maxConcurrentAgents = 2
  assert.throws(() => verifyInstance(instance), /must remain 1/)
})

test('repository workflow policy cannot escape its checkout', async () => {
  const instance = await load()
  instance.repositories[0].workflowPath = '../WORKFLOW.md'
  assert.throws(() => verifyInstance(instance), /must stay inside the repository/)
})

test('clone URL is derived from repository identity', async () => {
  const instance = await load()
  instance.repositories[0].cloneUrl = 'https://example.com/untrusted.git'
  assert.throws(() => verifyInstance(instance), /must match repository identity/)
})
