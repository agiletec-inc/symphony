import assert from 'node:assert/strict'
import { createHmac } from 'node:crypto'
import test from 'node:test'
import { normalizeGithubIssuePayload, syncGithubIssue, verifyGithubSignature } from '../scripts/github-linear-issue-sync.mjs'

const secret = 'test-secret'
const config = { linear: { teamId: 'team-1', projectId: 'project-1' } }
const response = (data) => ({ ok: true, status: 200, async json() { return { data } } })

test('verifies GitHub webhook signatures without accepting malformed input', () => {
  const body = '{"action":"opened"}'
  const signature = `sha256=${createHmac('sha256', secret).update(body).digest('hex')}`
  assert.equal(verifyGithubSignature(body, signature, secret), true)
  assert.equal(verifyGithubSignature(body, signature.slice(0, -1), secret), false)
  assert.equal(verifyGithubSignature(body, 'sha1=bad', secret), false)
})

test('normalizes only supported GitHub issue events', () => {
  const issue = { action: 'opened', repository: { full_name: 'agiletec-inc/agiletec' }, issue: { number: 12, title: 'Fix', body: 'Details', html_url: 'https://github.com/agiletec-inc/agiletec/issues/12', state: 'open' } }
  assert.deepEqual(normalizeGithubIssuePayload(issue), { action: 'opened', repository: 'agiletec-inc/agiletec', number: 12, title: 'Fix', body: 'Details', url: issue.issue.html_url, state: 'open' })
  assert.equal(normalizeGithubIssuePayload({ ...issue, action: 'labeled' }), null)
})

test('uses the GitHub URL attachment as an idempotent Linear mapping', async () => {
  const calls = []
  const fetchImpl = async (_url, request) => {
    const body = JSON.parse(request.body); calls.push(body)
    if (body.query.includes('TeamStates')) return response({ team: { states: { nodes: [{ id: 'todo', name: 'Todo' }, { id: 'done', name: 'Done' }] } } })
    if (body.query.includes('AttachmentsForUrl')) return response({ attachmentsForURL: { nodes: [] } })
    if (body.query.includes('IssueCreate')) return response({ issueCreate: { success: true, issue: { id: 'linear-1', identifier: 'AIS-1' } } })
    return response({ attachmentCreate: { success: true, attachment: { id: 'attachment-1' } } })
  }
  const result = await syncGithubIssue({ action: 'opened', repository: { full_name: 'agiletec-inc/agiletec' }, issue: { number: 12, title: 'Fix', body: 'Details', html_url: 'https://github.com/agiletec-inc/agiletec/issues/12', state: 'open' } }, config, { apiKey: 'test', fetchImpl })
  assert.equal(result.status, 'created')
  assert.equal(calls.filter((call) => call.query.includes('IssueCreate')).length, 1)
  assert.match(JSON.stringify(calls), /agiletec-inc\/agiletec\/issues\/12/)
})
