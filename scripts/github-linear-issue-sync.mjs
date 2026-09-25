import { createHmac, timingSafeEqual } from 'node:crypto'
import { createServer } from 'node:http'

const LINEAR_ENDPOINT = 'https://api.linear.app/graphql'
const MAX_BODY_BYTES = 1_000_000
const HANDLED_ACTIONS = new Set(['opened', 'edited', 'reopened', 'closed'])

const fail = (message) => { throw new Error(`[github-linear-sync] ${message}`) }

function requireEnv(name, env = process.env) {
  const value = env[name]
  if (typeof value !== 'string' || value.length === 0) fail(`missing ${name}`)
  return value
}

export function verifyGithubSignature(body, signature, secret) {
  if (typeof body !== 'string' || typeof signature !== 'string' || !signature.startsWith('sha256=')) return false
  const expected = Buffer.from(`sha256=${createHmac('sha256', secret).update(body).digest('hex')}`)
  const actual = Buffer.from(signature)
  return expected.length === actual.length && timingSafeEqual(expected, actual)
}

export function normalizeGithubIssuePayload(payload) {
  const repository = payload?.repository?.full_name
  const issue = payload?.issue
  if (typeof repository !== 'string' || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository)) return null
  if (!Number.isInteger(issue?.number) || issue.number < 1 || typeof issue.html_url !== 'string') return null
  if (!HANDLED_ACTIONS.has(payload.action)) return null
  return {
    action: payload.action,
    repository,
    number: issue.number,
    title: typeof issue.title === 'string' && issue.title.trim() ? issue.title.trim() : `GitHub Issue #${issue.number}`,
    body: typeof issue.body === 'string' ? issue.body : '',
    url: issue.html_url,
    state: issue.state === 'closed' ? 'closed' : 'open',
  }
}

async function linearRequest(query, variables, { fetchImpl = fetch, apiKey }) {
  const response = await fetchImpl(LINEAR_ENDPOINT, {
    method: 'POST',
    headers: { authorization: apiKey, 'content-type': 'application/json' },
    body: JSON.stringify({ query, variables }),
  })
  if (!response.ok) fail(`Linear HTTP ${response.status}`)
  const payload = await response.json()
  if (Array.isArray(payload.errors) && payload.errors.length > 0) fail('Linear GraphQL request failed')
  return payload.data
}

const teamQuery = `query TeamStates($teamId: String!) { team(id: $teamId) { states { nodes { id name type } } } }`
const existingAttachmentQuery = `query AttachmentsForUrl($url: String!) { attachmentsForURL(url: $url) { nodes { id issue { id identifier } } } }`
const issueCreateMutation = `mutation IssueCreate($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier } } }`
const issueUpdateMutation = `mutation IssueUpdate($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success issue { id identifier } } }`
const attachmentCreateMutation = `mutation AttachmentCreate($input: AttachmentCreateInput!) { attachmentCreate(input: $input) { success attachment { id } } }`

function stateId(states, names) {
  const wanted = new Set(names.map((name) => name.toLowerCase()))
  return states.find((state) => wanted.has(String(state.name).toLowerCase()))?.id
}

function issueDescription(issue) { return [`Source: ${issue.url}`, '', issue.body].join('\n').trim() }

export async function syncGithubIssue(payload, config, options = {}) {
  const issue = normalizeGithubIssuePayload(payload)
  if (!issue) return { status: 'ignored' }
  const apiKey = options.apiKey ?? requireEnv('LINEAR_API_KEY', options.env)
  const fetchImpl = options.fetchImpl ?? fetch
  const statesData = await linearRequest(teamQuery, { teamId: config.linear.teamId }, { fetchImpl, apiKey })
  const states = statesData.team?.states?.nodes ?? []
  const todoStateId = stateId(states, [config.linear.todoStateName ?? 'Todo'])
  const doneStateId = stateId(states, [config.linear.doneStateName ?? 'Done', 'Completed', 'Closed'])
  if (!todoStateId || !doneStateId) fail('Linear Todo/Done workflow states are missing')
  const existingData = await linearRequest(existingAttachmentQuery, { url: issue.url }, { fetchImpl, apiKey })
  const linkedIssue = existingData.attachmentsForURL?.nodes?.find((node) => node.issue?.id)?.issue
  const input = { title: `[${issue.repository}#${issue.number}] ${issue.title}`, description: issueDescription(issue), stateId: issue.state === 'closed' ? doneStateId : todoStateId }
  if (linkedIssue?.id) {
    const updated = await linearRequest(issueUpdateMutation, { id: linkedIssue.id, input }, { fetchImpl, apiKey })
    if (updated.issueUpdate?.success !== true) fail('Linear issue update was not successful')
    return { status: 'updated', linearIssueId: linkedIssue.id, identifier: linkedIssue.identifier }
  }
  input.teamId = config.linear.teamId
  if (config.linear.projectId) input.projectId = config.linear.projectId
  const created = await linearRequest(issueCreateMutation, { input }, { fetchImpl, apiKey })
  const createdIssue = created.issueCreate?.issue
  if (created.issueCreate?.success !== true || !createdIssue?.id) fail('Linear issue creation was not successful')
  const attached = await linearRequest(attachmentCreateMutation, { input: { issueId: createdIssue.id, title: `GitHub ${issue.repository}#${issue.number}`, subtitle: issue.state === 'closed' ? 'Closed' : 'Open', url: issue.url, metadata: { repository: issue.repository, issueNumber: String(issue.number) } } }, { fetchImpl, apiKey })
  if (attached.attachmentCreate?.success !== true) fail('Linear GitHub attachment was not created')
  return { status: 'created', linearIssueId: createdIssue.id, identifier: createdIssue.identifier }
}

function readRequest(request) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = []
    request.on('data', (chunk) => { size += chunk.length; if (size > MAX_BODY_BYTES) reject(new Error('payload too large')); else chunks.push(chunk) })
    request.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    request.on('error', reject)
  })
}

export function createGithubLinearSyncServer({ config, env = process.env, sync = syncGithubIssue } = {}) {
  const secret = requireEnv('GITHUB_WEBHOOK_SECRET', env)
  const queue = { tail: Promise.resolve() }
  const enqueue = (job) => { const result = queue.tail.then(job, job); queue.tail = result.catch(() => undefined); return result }
  return createServer(async (request, response) => {
    if (request.method !== 'POST' || request.url !== '/webhooks/github/issues') { response.writeHead(404).end(); return }
    try {
      const body = await readRequest(request)
      if (request.headers['x-github-event'] !== 'issues' || !verifyGithubSignature(body, request.headers['x-hub-signature-256'], secret)) { response.writeHead(401).end(); return }
      const result = await enqueue(() => sync(JSON.parse(body), config, { env }))
      response.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify(result))
    } catch (error) { response.writeHead(error.message === 'payload too large' ? 413 : 500).end() }
  })
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const config = { linear: { teamId: requireEnv('LINEAR_TEAM_ID'), projectId: process.env.LINEAR_PROJECT_ID, todoStateName: process.env.LINEAR_TODO_STATE_NAME ?? 'Todo', doneStateName: process.env.LINEAR_DONE_STATE_NAME ?? 'Done' } }
  const port = Number.parseInt(process.env.GITHUB_LINEAR_SYNC_PORT ?? '8787', 10)
  createGithubLinearSyncServer({ config }).listen(port, '127.0.0.1', () => console.info(`[github-linear-sync] listening on ${port}`))
}
