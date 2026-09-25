# AgileTech Symphony instance運用

## Owner

AgileTechのSymphony repository ownerとLinear workspace administrator。

## Trigger

pilot laneのbuild、synthetic検証、起動、停止、またはsecurity incident対応を行うときに使う。

## Authority

instance設定の正本は[`instance.json`](instance.json)である。対象repositoryはmanifestの
`workflowPath`にあるprompt policyだけを所有する。credential、workspace、log、生成workflow、
process stateはGitへ保存しない。

Linear project作成、credential発行、GitHub App権限付与、host tool導入、Ruleset変更、
production deploy設定変更はownerの事前承認が必要である。runtime statusが`approved`でない場合は
起動しない。

## Preflight

```sh
node scripts/verify-instance.mjs instances/agiletec-pilot/instance.json
node scripts/verify-linear-github-issues-sync.mjs
node scripts/audit-repository-boundary.mjs \
  instances/agiletec-pilot/instance.json agiletec /absolute/agiletec/checkout
```

live repository inventoryを確認するときだけ、認証済みoperator環境から次を実行する。

```sh
node scripts/verify-linear-github-issues-sync.mjs --live
```

## Build and synthetic verification

repository外の新しいartifact directoryを指定する。

```sh
sh instances/agiletec-pilot/build-official.sh /absolute/artifact/directory
sh instances/agiletec-pilot/test-synthetic-config.sh /absolute/artifact/directory
```

artifact source、commit、digest固定build imageは`build-manifest.json`で確認する。artifactをGitへ
vendorまたはcommitしない。

## Start

hostのservice managerだけがcredentialとruntime directoryを保持する。値をlogへ出力せず、必要な
環境変数の存在だけを確認してlaneを起動する。

```sh
sh scripts/run-instance-lane.sh \
  instances/agiletec-pilot/instance.json agiletec /absolute/agiletec/checkout \
  /absolute/artifact/symphony /absolute/config/root /absolute/log/root
```

dashboard用portは指定しない。pilotは最大同時実行1で、`symphony-pilot`とrepository labelを持つ
Issueだけを処理する。

## Stop and verification

service managerから通常終了signalを送り、process停止を確認する。強制終了を先に使わない。
service log、Linear Issueの単一`## Codex Workpad`、対象workspaceの順に確認する。

受入条件:

- labelなし、またはactive state外のIssueがdispatchされない。
- 対象Issueが1件だけ隔離workspaceで開始される。
- repository、Issue、PR、log、artifactにcredentialが存在しない。
- review、required checks、repository admission、default branch包含前にDoneへ進まない。

## Rollback

processを通常停止し、pilot Issueから`symphony-pilot` labelを外す。workspaceとLinear projectは調査用に
保持する。credential疑義があればhost側で失効し、repositoryへfallback credentialを追加しない。

## Escalation

意図しないdispatch、同時実行数超過、workspace外write、credential露出、production dataまたは
trafficへの接触を検知したら即時停止する。credential露出時は失効と監査が完了するまで再起動しない。

## Update trigger

instance manifest、runtime pin、credential owner、lane、security exception、起動interfaceのいずれかが
変わる変更と同じPRで更新する。pilot廃止時はrunbookも削除する。
