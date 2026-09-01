# AgileTech Symphony instance

このdirectoryは、AgileTechが運用するSymphony instance全体のmachine-readableな正本である。
`instance.json`はtracker scope、runtime pin、総capacity、repository lane inventoryを所有する。
対象repositoryは自身の`workflowPath`にあるprompt policyを所有し、instance設定を複製しない。
lane別`WORKFLOW.md`はrepository外へ生成するruntime artifactでありGitへcommitしない。

credential、workspace、log、生成workflow、process stateは保存しない。`runtime.status`が`approved`でない
instanceは起動できない。

権限を伴うbuild、起動、停止、incident対応は[`RUNBOOK.md`](RUNBOOK.md)に従う。

```sh
node scripts/verify-instance.mjs instances/agiletec-pilot/instance.json
node scripts/verify-linear-github-issues-sync.mjs
node --test tests/*.test.mjs
sh scripts/run-instance-lane.sh \
  instances/agiletec-pilot/instance.json agiletec /absolute/repository/checkout \
  /absolute/symphony /absolute/config/root /absolute/log/root
```
