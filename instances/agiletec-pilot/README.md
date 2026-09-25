# AgileTech Symphony instance

このdirectoryは、AgileTechが運用するSymphony instance全体のmachine-readableな正本である。
`instance.json`はtracker scope、runtime pin、総capacity、repository lane inventoryを所有する。
対象repositoryは自身の`workflowPath`にあるprompt policyを所有し、instance設定を複製しない。
lane別`WORKFLOW.md`はrepository外へ生成するruntime artifactでありGitへcommitしない。

Codexのsandbox、approval、network設定はportableなagent行動規範ではなく、workspace・credential・外部通信を
制限するinstance runtime permission boundaryである。このためhost個体のglobal設定から注入せず、生成workflowで
再現可能かつfail-closedに固定する。portableな判断・skillはglobal `~/.agents`、製品固有promptは対象repositoryが
それぞれ所有する。

credential、workspace、log、生成workflow、process stateは保存しない。`runtime.status`が`approved`でない
instanceは起動できない。

権限を伴うbuild、起動、停止、incident対応は[`RUNBOOK.md`](RUNBOOK.md)に従う。

```sh
node scripts/verify-instance.mjs instances/agiletec-pilot/instance.json
node scripts/verify-linear-github-issues-sync.mjs
node --test tests/*.test.mjs
node --test tests/github-linear-issue-sync.test.mjs
sh scripts/run-instance-lane.sh \
  instances/agiletec-pilot/instance.json agiletec /absolute/repository/checkout \
  /absolute/symphony /absolute/config/root /absolute/log/root
```

The host-side consumer is [`scripts/github-linear-issue-sync.mjs`](../../scripts/github-linear-issue-sync.mjs).
It accepts only signed GitHub App `issues` events at `/webhooks/github/issues`, creates or updates the
configured Linear team issue in `Todo`/`Done`, and uses the GitHub Issue URL as an idempotent Linear
attachment. `LINEAR_API_KEY` and `GITHUB_WEBHOOK_SECRET` are host-only environment variables; they are
never placed in workflow, Issue, log, or GitHub Actions configuration.
