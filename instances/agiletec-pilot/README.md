# AgileTech Symphony instance

このdirectoryは、AgileTechが運用するSymphony instance全体のmachine-readableな正本である。

`instance.json`はtracker scope、runtime pin、総capacity、repository lane inventoryを所有する。
対象repositoryは自身の`workflowPath`にあるworkflow policyを所有し、Symphony instanceはその内容を
複製しない。laneごとの実行用`WORKFLOW.md`は両者からrepository外へ生成するruntime artifactであり、
Gitへcommitしない。

credential、workspace、log、生成workflow、process stateはこのdirectoryへ保存しない。
`runtime.status`が`approved`でないinstanceは起動できない。

検証:

```sh
node scripts/verify-instance.mjs instances/agiletec-pilot/instance.json
node --test tests/instance-boundary.test.mjs
```

起動時はhostのservice managerから、credentialを値として引数へ渡さず次を実行する。

```sh
sh scripts/run-instance-lane.sh \
  instances/agiletec-pilot/instance.json agiletec /absolute/repository/checkout \
  /absolute/symphony /absolute/config/root /absolute/log/root
```
