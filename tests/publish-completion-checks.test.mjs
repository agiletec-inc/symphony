import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import {
  buildCheckRunCommand,
  buildCheckRunLookupCommand,
  buildCheckRunUpdateCommand,
  COMPLETION_CHECK_NAMES,
  hostGhEnvironment,
  publishCompletionChecks,
} from '../scripts/publish-completion-checks.mjs'

const mergeSha = 'a'.repeat(40)

test('builds a host-authenticated check-run command pinned to the merge commit', () => {
  assert.deepEqual(
    buildCheckRunCommand({
      repo: 'owner/repo',
      name: COMPLETION_CHECK_NAMES.runtime,
      mergeSha,
      conclusion: 'success',
    }),
    [
      'gh',
      'api',
      '--method',
      'POST',
      'repos/owner/repo/check-runs',
      '-f',
      'name=symphony-runtime',
      '-f',
      `head_sha=${mergeSha}`,
      '-f',
      'status=completed',
      '-f',
      'conclusion=success',
    ]
  )
})

test('looks up and updates the latest check run instead of creating duplicates', () => {
  assert.match(
    buildCheckRunLookupCommand({ repo: 'owner/repo', name: COMPLETION_CHECK_NAMES.runtime, mergeSha }).join(' '),
    /check_name=symphony-runtime/
  )
  assert.deepEqual(
    buildCheckRunUpdateCommand({ repo: 'owner/repo', checkRunId: 42, conclusion: 'failure' }).slice(-4),
    ['-f', 'status=completed', '-f', 'conclusion=failure']
  )
})

test('removes token environment variables before invoking gh', () => {
  const env = hostGhEnvironment({ GH_TOKEN: 'redacted', GITHUB_TOKEN: 'redacted', PATH: '/bin' })
  assert.deepEqual(env, { PATH: '/bin' })
})

test('runs both checks at the merge SHA and publishes a failure without masking it', async () => {
  const root = await mkdtemp(join(tmpdir(), 'symphony-completion-test-'))
  const calls = []
  try {
    let error
    try {
      await publishCompletionChecks({
        repo: 'owner/repo',
        mergeSha,
        checkout: '/repo',
          acceptanceCommand: ['pnpm', 'acceptance'],
          runtimeCommand: ['pnpm', 'runtime'],
        tempRoot: root,
        run: async (command, options) => {
          calls.push({ command, options })
          if (command[0] === 'pnpm' && command[1] === 'runtime') throw new Error('red')
          if (command[0] === 'gh' && command[1] === 'api' && command.includes('--jq')) return ''
          return ''
        },
      })
    } catch (caught) {
      error = caught
    }
    assert.match(error?.message ?? '', /symphony-runtime verification failed/)
    const published = calls.filter(
      (entry) => entry.command[0] === 'gh' && entry.command.some((argument) => argument.startsWith('conclusion='))
    )
    assert.equal(published.length, 2)
    assert.ok(published[0].command.includes('conclusion=success'))
    assert.ok(published[1].command.includes('conclusion=failure'))
    assert.equal(calls.filter((entry) => entry.command[0] === 'pnpm').length, 2)
    assert.ok(calls.some((entry) => entry.command.slice(0, 4).join(' ') === 'git worktree remove --force'))
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('publishes acceptance failure and still runs runtime verification', async () => {
  const root = await mkdtemp(join(tmpdir(), 'symphony-completion-acceptance-failure-'))
  const calls = []
  try {
    await assert.rejects(
      () =>
        publishCompletionChecks({
          repo: 'owner/repo',
          mergeSha,
          checkout: '/repo',
          acceptanceCommand: ['pnpm', 'acceptance'],
          runtimeCommand: ['pnpm', 'runtime'],
          tempRoot: root,
          run: async (command) => {
            calls.push(command)
            if (command[0] === 'pnpm' && command[1] === 'acceptance') throw new Error('red')
            if (command[0] === 'gh' && command.includes('--jq')) return ''
            return ''
          },
        }),
      /symphony-acceptance verification failed/
    )
    assert.deepEqual(
      calls.filter((command) => command[0] === 'pnpm').map((command) => command[1]),
      ['acceptance', 'runtime']
    )
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('updates an existing check run instead of creating another one', async () => {
  const root = await mkdtemp(join(tmpdir(), 'symphony-completion-update-'))
  const calls = []
  try {
    await publishCompletionChecks({
      repo: 'owner/repo',
      mergeSha,
      checkout: '/repo',
      acceptanceCommand: ['pnpm', 'acceptance'],
      runtimeCommand: ['pnpm', 'runtime'],
      tempRoot: root,
      run: async (command) => {
        calls.push(command)
        if (command[0] === 'gh' && command.includes('--jq')) return '42\n'
        return ''
      },
    })
    const updates = calls.filter((command) => command.includes('--method') && command.includes('PATCH'))
    assert.equal(updates.length, 2)
    assert.equal(calls.filter((command) => command.includes('POST')).length, 0)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('rejects an unbounded command before touching git', async () => {
  const calls = []
  await assert.rejects(
    () =>
      publishCompletionChecks({
        repo: 'owner/repo',
        mergeSha,
        checkout: '/repo',
        acceptanceCommand: ['x'.repeat(1001)],
        runtimeCommand: ['pnpm', 'runtime'],
        run: async (command) => calls.push(command),
      }),
    /acceptanceCommand must be a bounded/
  )
  assert.equal(calls.length, 0)
})
