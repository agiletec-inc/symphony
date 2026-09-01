import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { readAndVerifyInstance } from './verify-instance.mjs'

const fail = (message) => {
  throw new Error(`[symphony-lane] ${message}`)
}

const yamlString = (value) => JSON.stringify(value)

export async function renderLaneWorkflow({ manifestPath, repositoryName, checkout, output }) {
  const instance = await readAndVerifyInstance(manifestPath, { runtime: true })
  const lane = instance.repositories.find((candidate) => candidate.name === repositoryName)
  if (!lane) fail(`unknown repository lane: ${repositoryName}`)
  if (!lane.enabled) fail(`repository lane is disabled: ${repositoryName}`)

  const policyPath = resolve(checkout, lane.workflowPath)
  const policy = await readFile(policyPath, 'utf8').catch((error) => {
    fail(`cannot read repository workflow policy ${policyPath}: ${error.message}`)
  })
  if (policy.startsWith('---\n') || policy.startsWith('---\r\n')) {
    fail('repository workflow policy must not contain instance-owned YAML front matter')
  }
  if (policy.trim() === '') fail('repository workflow policy must not be blank')

  const workflow = `---
tracker:
  kind: ${yamlString(instance.tracker.kind)}
  provider:
    project_slug: ${yamlString(instance.tracker.projectSlug)}
  required_labels:
    - ${yamlString(instance.tracker.commonRequiredLabel)}
    - ${yamlString(lane.requiredLabel)}
  active_states:
    - Todo
    - In Progress
    - Rework
  terminal_states:
    - Done
    - Cancelled
    - Canceled
    - Duplicate
polling:
  interval_ms: 30000
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --filter=blob:none ${yamlString(lane.cloneUrl)} .
agent:
  max_concurrent_agents: ${instance.capacity.maxConcurrentAgents}
  max_turns: 20
  max_retry_backoff_ms: 300000
codex:
  command: codex app-server
  approval_policy:
    reject:
      sandbox_approval: true
      rules: true
      mcp_elicitations: true
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
---

${policy.trim()}\n`

  await mkdir(dirname(output), { recursive: true })
  await writeFile(output, workflow, { encoding: 'utf8', flag: 'wx' }).catch((error) => {
    fail(`cannot create generated workflow ${output}: ${error.message}`)
  })
  return workflow
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [manifestPath, repositoryName, checkout, output] = process.argv.slice(2)
  if (!manifestPath || !repositoryName || !checkout || !output) {
    fail('usage: render-lane-workflow.mjs <instance.json> <lane> <repo-checkout> <output>')
  }
  await renderLaneWorkflow({ manifestPath, repositoryName, checkout, output })
  console.log(`[symphony-lane] rendered ${repositoryName} to ${output}`)
}
