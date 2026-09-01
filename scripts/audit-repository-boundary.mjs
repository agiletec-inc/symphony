import { access, readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { readAndVerifyInstance } from './verify-instance.mjs'

const legacyAuthorities = [
  'deployment/symphony/upstream.json',
  'deployment/symphony/repo-lanes.json',
  'deployment/symphony/linear-github-issues-sync.json',
]

const exists = async (file) => access(file).then(() => true, () => false)

export async function auditRepositoryBoundary({ manifestPath, repositoryName, checkout }) {
  const instance = await readAndVerifyInstance(manifestPath)
  const lane = instance.repositories.find((candidate) => candidate.name === repositoryName)
  if (!lane) throw new Error(`[symphony-boundary] unknown repository lane: ${repositoryName}`)

  const findings = []
  const policyPath = resolve(checkout, lane.workflowPath)
  const policy = await readFile(policyPath, 'utf8').catch(() => null)
  if (policy === null) findings.push(`missing repository workflow policy: ${lane.workflowPath}`)
  else if (policy.startsWith('---\n') || policy.startsWith('---\r\n')) {
    findings.push(`repository workflow policy contains instance-owned front matter: ${lane.workflowPath}`)
  }

  const legacyWorkflow = resolve(checkout, 'WORKFLOW.md')
  if (lane.workflowPath !== 'WORKFLOW.md' && await exists(legacyWorkflow)) {
    const source = await readFile(legacyWorkflow, 'utf8')
    for (const value of [
      instance.tracker.projectSlug,
      instance.tracker.commonRequiredLabel,
      lane.requiredLabel,
    ]) {
      if (source.includes(value)) findings.push(`legacy WORKFLOW.md duplicates instance authority: ${value}`)
    }
  }

  for (const relative of legacyAuthorities) {
    if (await exists(resolve(checkout, relative))) {
      findings.push(`legacy consumer-owned instance authority remains: ${relative}`)
    }
  }

  if (findings.length > 0) {
    throw new Error(`[symphony-boundary] repository migration incomplete:\n- ${findings.join('\n- ')}`)
  }
  return { lane, policyPath }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [manifestPath, repositoryName, checkout] = process.argv.slice(2)
  if (!manifestPath || !repositoryName || !checkout) {
    throw new Error('usage: audit-repository-boundary.mjs <instance.json> <lane> <repo-checkout>')
  }
  await auditRepositoryBoundary({ manifestPath, repositoryName, checkout })
  console.log(`[symphony-boundary] OK (${repositoryName})`)
}
