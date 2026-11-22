# Linear control acceptance contract

This document defines required behavior, not completed deployment evidence.

1. Linear shows stage, concise summary, wait reason, next action, PR, tests,
   and actual execution model. Follow-up instructions and stop/resume work there.
2. Native Agent Sessions bind new issues and selected Terminal conversations.
   Preserve the selected thread and workspace snapshot, including unfinished work.
   Never mutate the source repository or export unrelated conversations.
3. Monitoring, signature validation, deduplication, CI polling, and retry timers
   are application code. Idle operation produces zero model turns and no repeated
   Linear activities. Normal implementation and fresh independent review use Luna.
   Astra is reserved for explicit high-value acceptance and architecture decisions.
4. Validate the raw-body HMAC and signed JSON timestamp. Match organization,
   app user, OAuth client, and authoritative project/session scope. Persist input
   before acknowledgement. Delivery header changes cannot duplicate instructions.
5. Known-session stop interrupts work without waiting for a provider lookup.
   Worker exit, restart, and old CI results cannot undo a pause. A new explicit
   instruction resumes the saved thread once.
6. Persist a stable activity UUID before publication. Validate returned identity
   and success; reconcile ambiguous results before retrying. Failed initial
   publication prevents dispatch. Meet the five-second webhook response deadline
   and ten-second initial activity target without an LLM call.
7. Report operational progress and results, never credentials, private reasoning,
   or raw unrelated logs. Distinguish requested from returned model metadata.
   Do not infer weekly quota savings from token totals.
8. A supervised service recovers from process and host restart using approved
   deployment and credential owners. Verify one new Linear task and one selected
   Terminal continuation live, including stop/resume and fresh review results.
   Local mock/protocol tests alone do not satisfy this acceptance contract.

References:

- [Linear Agent interaction](https://linear.app/developers/agent-interaction)
- [Linear Webhooks](https://linear.app/developers/webhooks)

## Selected Terminal snapshot behavior

The importer preserves staged changes, unstaged changes, binary contents, and
nonignored untracked regular files, including executable permissions. It leaves
the source HEAD, index, and working files intact. A fingerprint covers the chosen
snapshot; changes during capture or a different snapshot on retry are refused.
Symlink and submodule entries are currently refused. These cases need an explicit
supported import strategy before they can be used in a live handoff.

Before asking Codex to fork, the importer saves a prepared record. An uncertain
fork result remains unresolved instead of issuing another fork. Source thread
metadata is read from a separate validated directory; the fork uses the isolated
destination and explicitly applies Symphony model and execution policy settings.
Returned fork identity, cwd, model, approval policy, and sandbox type are checked.
The CLI now submits a local request to the enabled daemon Control owner. It does
not start a second Control process or execute a model turn. The selected source
snapshot and summary are fingerprinted at submission and checked before import.
A changed selection is refused. Saved completed imports can restore the Control
binding without another fork; a different source path or summary is refused.

```sh
mix symphony.terminal_handoff --state-root /absolute/daemon-state \
  --source /absolute/source-repository --issue ISSUE-ID \
  --thread SELECTED-THREAD-ID --summary /absolute/selected-summary.md
```

The state directory must be the same one configured for the running daemon.
Requests remain queued while the daemon is offline. The daemon processes one
handoff at a time outside its control mailbox. A reservation excludes an agent
run for that issue during import. Interrupted imports become `unknown` on restart
and are not automatically forked again. Local request metadata is available from
`SymphonyElixir.Control.HandoffInbox.status/2`.

When native sessions are enabled, intake resolves the issue reference to its
canonical Linear ID and verifies the current app actor, organization, and project
before importing. A completed import attaches an existing authorized session or
creates one with `agentSessionCreateOnIssue`. The controller persists the pending
creation before sending that mutation. An ambiguous response remains unresolved
across restart and cannot trigger another create automatically. A confirmed binding
queues the fixed initial activity without an LLM turn. Late created notifications
cannot replace an existing session binding or inject generic issue context into
the imported conversation.

This is local integration evidence, not live deployment acceptance. Structured
validation/PR/review result publication, live Luna review verification, and approved service
deployment still remain before the user can operate this flow entirely from Linear.

## Operational state activities

The controller projects state transitions through fixed messages. Running and CI
waiting use `thought`, user judgment uses `elicitation`, failure uses `error`, and
completion uses `response`. This changes the native Linear session presentation
without generating text with an LLM. Conversation bodies, source summaries, error
logs, and arbitrary activity content are not accepted by this projection.

Each transition has a durable UUID and per-session sequence. Repeated publication
of the same state does not enqueue another activity. Startup restores primary
pending records before activating the sender, including when the secondary outbox
file was lost. A session cannot overtake its earlier pending activity; another
session can continue while that head waits for retry. A single timer waits for the
next eligible session head. Repeated failures switch to a 60-second retry interval
and expose `native_delivery_delayed` in Control state; they no longer permanently
disable recovery. All retries reconcile the same activity ID before creation.

These fixed status messages are not yet the complete result surface: detailed
acceptance results, the verified PR link, and independent review findings still
need their structured reporting path and live verification.

## Execution model confirmation

Native runs explicitly request Luna. App Server thread start and resume responses
must confirm the requested model in the response-level model field before a turn
can begin. A missing or different model fails the session; a resumed thread must
also return the selected saved thread ID. Runtime identity records use the returned
model rather than copying the requested configuration. This verifies model routing,
not weekly quota savings or completion of the independent review workflow.

## Structured turn outcomes

The local outcome contract separates implementation claims from independent review
verdicts. Implementation reports `needs_review`, `waiting_user`, or `waiting_ci`;
review reports `approve`, `changes_requested`, or `needs_judgment`. Neither contract
accepts an implementation claim of reviewed completion. Both require a bounded,
nonempty summary and reject extra fields. These summaries remain local until a
separate scoped reporting path is implemented; validation is not proof that tests
passed or that a PR exists. Native AgentRunner routing consumes this contract to
select independent review or a durable waiting state.

App Server supports a per-turn `output_schema` option using the native
`turn/start.outputSchema` contract. Structured turns accept one JSON object from
a matching `item/completed` agent message with `phase: final_answer`, then require
a matching successful `turn/completed`. Missing, duplicate, malformed, oversized,
or unsuccessful results fail closed. Intermediate messages and other thread/turn
notifications cannot provide the result. Collection stays in the receive-loop
context and does not share process-dictionary state across turns.

## Independent review runner

`Control.Reviewer.run/5` starts one fresh Luna thread for a validated
`needs_review` implementation result. It does not resume or fork the implementation
conversation. The prompt contains the selected request, issue requirements, and
implementation summary as untrusted task material. The reviewer inspects the
workspace and evidence, returns the review outcome schema, and always closes its
session after the turn. Waiting outcomes and invalid requests cannot start review.

The review session requests read-only sandboxing, no network access, and no approval
escalation. The returned cwd, approval policy, sandbox, and model must match before
a turn starts. Dynamic Linear tools are neither advertised nor executable through
the review callback. Native AgentRunner now calls this runner for `needs_review`.
Live acceptance and deployment remain unverified.

Native runs request the implementation outcome schema. A review approval records
completion of that run, with separate implementation and reviewer identities; it
does not merge a PR or deploy anything. Changes requested resume the implementation
thread for repair, with at most three implementation/review rounds (or a lower
`agent.max_turns`). Exhaustion and reviewer judgment requests return to user judgment.
CI waiting starts no reviewer. Normal worker exit preserves completed/CI-waiting
states, newer user input takes precedence, and persisted pause cannot be cleared by
a stale completion. Paused records are checked before App Server startup. Detailed
reports remain local; fixed operational phases are the current Linear projection.

## Durable CI wake contract

`Control.arm_ci_wait/3` binds a native CI wait to a validated GitHub PR URL,
40-character commit SHA, and generated wait ID. `Control.apply_ci_result/4`
accepts a matching, nonempty rollup only after all recognized checks have ended.
Failure conclusions can trigger inspection; this is never a success verdict.
Unknown, missing, empty, or oversized rollups remain pending. A replaced wait or
a different PR/head cannot wake the issue. Paused state, new user input, and an
active run take precedence.

The consumed wait and one fixed continuation prompt are saved together before
returning. Repeated results and controller restart cannot enqueue another prompt.
An already-consumed PR/head cannot automatically rearm; same-commit CI reruns need
a distinct verified run-generation strategy before automatic support. These are
state APIs consumed by the Control-owned CI monitor. A native waiting-CI transition
requests PR discovery, after which polling uses the saved PR and commit. The old `ci_event/2` ETS seam is not this durable mechanism.

Field reference: [GitHub CLI PR view](https://cli.github.com/manual/gh_pr_view).

The owned CI monitor runs serially every 30 seconds. It selects native CI-waiting
records with a workspace, no active run, no pending input, and no pause. New waits
discover the current branch PR; subsequent reads use the saved target. Provider
errors leave the wait unresolved and do not prevent other issues from being read.
A timer token prevents canceled notifications from scheduling duplicate polls.
Control shutdown terminates its monitor, including an in-flight provider read.

The provider reads local HEAD/origin/branch, uses `gh pr view` with an explicit
repository and branch or saved URL, then rechecks local HEAD/origin/branch. Only
GitHub HTTPS or SSH origins are supported; credential-bearing and foreign-host
URLs are rejected. PR repository and head must match the selected workspace.
Commands use argument arrays, a 3-second per-command deadline, and a 1-MiB output
limit. Existing GitHub CLI authentication is used without printing credentials.
Errors do not include raw command output.

The JSON projection and check pagination were verified against installed GitHub
CLI 2.100.0 source: [PR export](https://raw.githubusercontent.com/cli/cli/v2.100.0/api/export_pr.go)
and [PR finder](https://raw.githubusercontent.com/cli/cli/v2.100.0/pkg/cmd/pr/shared/finder.go).
Provider tests use injected reads plus a native Git command failure; live GitHub
CI completion and a resulting model continuation still require acceptance evidence.

## Explicit resume from persisted pause

A native stop activity is recorded as consumed control input, so it is never
executed as a task prompt. While paused, ordinary follow-up instructions remain
queued and the state stays waiting for user input. A message consisting of
`resume`, `/resume`, or `再開` (ignoring surrounding whitespace and English case)
clears the pause and preserves queued input order. Redelivering an old resume
activity cannot undo a later stop, including after controller restart.

The fixed paused activity explains that subsequent execution is held, a matching
running turn receives an interrupt request, and `再開` resumes work after the
pause is cleared.
