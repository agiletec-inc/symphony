# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Linear session control

The Elixir implementation includes an opt-in extension for native Linear Agent
Sessions and selected Codex Terminal handoffs. It is intended to keep operational
progress, follow-up instructions, and human decisions in Linear while ordinary
application code handles monitoring. Normal execution uses an explicitly checked
Luna model. See the [control acceptance contract](elixir/docs/linear-control.md)
for the required end-to-end behavior; local protocol tests do not establish that
an instance has been deployed or accepted for unattended use.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).

Native Linear sessions use structured implementation outcomes to select CI/user
waiting or a fresh read-only Luna review. Review repair is bounded to three rounds
(or a lower `agent.max_turns`); reviewer approval completes the run without merging
or deploying. Worker exit preserves the selected state, while newer input and
persisted pause take precedence. This path still requires live acceptance.

Native CI waits are monitored by Control every 30 seconds without a model. The
GitHub CLI adapter binds reads to the workspace repository and commit, and a
matching terminal rollup queues one durable continuation. Unknown results stay
pending, and CI failure is not reported as success. Live acceptance remains required.

Persisted native pause is cleared only by explicit `resume`, `/resume`, or `再開`.
Ordinary follow-ups stay queued while paused; stop activities are control inputs
and are never executed as task prompts. Current pause holds subsequent execution;
interruption of an already-running agent remains unimplemented pending approval.
