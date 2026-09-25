import { execFile } from 'node:child_process'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

export const COMPLETION_CHECK_NAMES = Object.freeze({
  acceptance: 'symphony-acceptance',
  runtime: 'symphony-runtime',
})

const REPOSITORY_PATTERN = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/
const FULL_SHA_PATTERN = /^[0-9a-f]{40}$/i
const MAX_COMMAND_LENGTH = 1_000
const MAX_COMMAND_ARGS = 32
const COMMAND_TIMEOUT_MS = 15 * 60 * 1_000
const GH_TOKEN_ENV_NAMES = [
  'GH_TOKEN',
  'GITHUB_TOKEN',
  'GH_ENTERPRISE_TOKEN',
  'GITHUB_ENTERPRISE_TOKEN',
]
const VERIFICATION_ENV_NAMES = [
  'PATH',
  'TMPDIR',
  'TMP',
  'TEMP',
  'LANG',
  'LC_ALL',
  'CI',
  'NODE_ENV',
  'TZ',
  'TERM',
  'TERM_PROGRAM',
  'FORCE_COLOR',
  'NO_COLOR',
]

function fail(message) {
  throw new Error(`[symphony-completion] ${message}`)
}

function validateInput({ repo, mergeSha, checkout, acceptanceCommand, runtimeCommand }) {
  if (typeof repo !== 'string' || !REPOSITORY_PATTERN.test(repo)) fail('repo must be owner/name')
  if (typeof mergeSha !== 'string' || !FULL_SHA_PATTERN.test(mergeSha)) {
    fail('mergeSha must be a full commit SHA')
  }
  if (typeof checkout !== 'string' || !checkout.startsWith('/')) fail('checkout must be absolute')
  for (const [name, command] of [
    ['acceptanceCommand', acceptanceCommand],
    ['runtimeCommand', runtimeCommand],
  ]) {
    if (
      !Array.isArray(command) ||
      command.length === 0 ||
      command.length > MAX_COMMAND_ARGS ||
      command.some((argument) => typeof argument !== 'string' || argument.length === 0) ||
      command.join('\0').length > MAX_COMMAND_LENGTH
    ) {
      fail(`${name} must be a bounded non-empty argv array`)
    }
  }
}

export function buildCheckRunCommand({ repo, name, mergeSha, conclusion }) {
  if (!['success', 'failure'].includes(conclusion)) fail('check conclusion must be success or failure')
  return [
    'gh',
    'api',
    '--method',
    'POST',
    `repos/${repo}/check-runs`,
    '-f',
    `name=${name}`,
    '-f',
    `head_sha=${mergeSha}`,
    '-f',
    'status=completed',
    '-f',
    `conclusion=${conclusion}`,
  ]
}

export function buildCheckRunLookupCommand({ repo, name, mergeSha }) {
  return [
    'gh',
    'api',
    '--method',
    'GET',
    `repos/${repo}/commits/${mergeSha}/check-runs`,
    '-f',
    `check_name=${name}`,
    '-f',
    'per_page=100',
    '--jq',
    '.check_runs | sort_by(.id) | last | .id // empty',
  ]
}

export function buildCheckRunUpdateCommand({ repo, checkRunId, conclusion }) {
  if (!['success', 'failure'].includes(conclusion)) fail('check conclusion must be success or failure')
  return [
    'gh',
    'api',
    '--method',
    'PATCH',
    `repos/${repo}/check-runs/${checkRunId}`,
    '-f',
    'status=completed',
    '-f',
    `conclusion=${conclusion}`,
  ]
}

export function hostGhEnvironment(env = process.env) {
  const result = { ...env }
  for (const name of GH_TOKEN_ENV_NAMES) delete result[name]
  return result
}

export function verificationEnvironment(env = process.env) {
  return Object.fromEntries(
    VERIFICATION_ENV_NAMES
      .filter((name) => typeof env[name] === 'string')
      .map((name) => [name, env[name]])
  )
}

const runDefault = (command, options = {}) =>
  new Promise((resolve, reject) => {
    execFile(
      command[0],
      command.slice(1),
      {
        cwd: options.cwd,
        env: options.env ?? process.env,
        timeout: COMMAND_TIMEOUT_MS,
        maxBuffer: 1_000_000,
      },
      (error, stdout) => {
        if (error) return reject(error)
        resolve(stdout)
      }
    )
  })

async function publishCheckRun({ run, repo, name, mergeSha, conclusion, checkout }) {
  const output = await run(buildCheckRunLookupCommand({ repo, name, mergeSha }), {
    cwd: checkout,
    env: hostGhEnvironment(),
  })
  const checkRunId = Number.parseInt(String(output).trim(), 10)
  const command = Number.isSafeInteger(checkRunId) && checkRunId > 0
    ? buildCheckRunUpdateCommand({ repo, checkRunId, conclusion })
    : buildCheckRunCommand({ repo, name, mergeSha, conclusion })
  await run(command, { cwd: checkout, env: hostGhEnvironment() })
}

export async function publishCompletionChecks({
  repo,
  mergeSha,
  checkout,
  acceptanceCommand,
  runtimeCommand,
  tempRoot = tmpdir(),
  run = runDefault,
}) {
  validateInput({ repo, mergeSha, checkout, acceptanceCommand, runtimeCommand })
  await run(['git', 'fetch', '--atomic', '--prune', 'origin'], { cwd: checkout })
  await run(['git', 'rev-parse', '--verify', `${mergeSha}^{commit}`], { cwd: checkout })

  const worktree = await mkdtemp(join(tempRoot, 'symphony-completion-'))
  let worktreeAdded = false
  const failures = []
  const results = {}
  let worktreeRemoved = false
  try {
    await run(['git', 'worktree', 'add', '--detach', worktree, mergeSha], { cwd: checkout })
    worktreeAdded = true
    for (const [kind, command] of [
      ['acceptance', acceptanceCommand],
      ['runtime', runtimeCommand],
    ]) {
      const name = COMPLETION_CHECK_NAMES[kind]
      let conclusion = 'success'
      try {
        await run(command, { cwd: worktree, env: verificationEnvironment() })
      } catch {
        conclusion = 'failure'
        failures.push(`${name} verification failed`)
      }
      try {
        await publishCheckRun({ run, repo, name, mergeSha, conclusion, checkout })
      } catch {
        failures.push(`${name} check publication failed`)
      }
      results[kind] = { status: conclusion === 'success' ? 'PASS' : 'FAIL', sourceSha: mergeSha }
    }
  } finally {
    if (worktreeAdded) {
      try {
        await run(['git', 'worktree', 'remove', '--force', worktree], { cwd: checkout })
        worktreeRemoved = true
      } catch {
        failures.push('completion worktree cleanup failed')
      }
    }
    if (!worktreeAdded || worktreeRemoved) {
      try {
        await rm(worktree, { recursive: true, force: true })
      } catch {
        failures.push('completion temporary directory cleanup failed')
      }
    }
  }
  if (failures.length > 0) fail(failures.join('; '))
  return results
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [repo, mergeSha, checkout, acceptanceCommandJson, runtimeCommandJson] = process.argv.slice(2)
  if (!repo || !mergeSha || !checkout || !acceptanceCommandJson || !runtimeCommandJson) {
    fail('usage: publish-completion-checks.mjs <owner/name> <merge-sha> <checkout> <acceptance-argv-json> <runtime-argv-json>')
  }
  let acceptanceCommand
  let runtimeCommand
  try {
    acceptanceCommand = JSON.parse(acceptanceCommandJson)
    runtimeCommand = JSON.parse(runtimeCommandJson)
  } catch {
    fail('acceptance and runtime commands must be JSON argv arrays')
  }
  await publishCompletionChecks({ repo, mergeSha, checkout, acceptanceCommand, runtimeCommand })
  console.info('[symphony-completion] checks published')
}
