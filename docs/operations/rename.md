# Homebrew 配布名称変更 runbook

名称変更でも、この public Tap は Formula、`formula_renames.json`、公開可能なmetadataだけを所有します。source manifest import、Formula candidate生成、bottle build / publish、canary、candidate PR更新は private `zoe-llc/crewcli-distribution` で行います。

## 不変条件

- stable release identity、既存SemVer、source SHA、manifest SHA-256を変えない。
- 旧Release、旧GHCR manifest / tag / blob、旧Formula historyを上書き・削除しない。
- rename mappingをchainにせず、すべてのlegacy名を新Formulaへ直接向ける。
- 直前primary commandを同じentrypointへのaliasとして最低2件のlive releaseで維持する。
- public Tapへautomation secret、package permission、protected artifact、mutation workflowを追加しない。

例えば将来 `crewent` を `future-name` へ変更する場合は、stable PRで次の直接mappingを追加します。

```json
{
  "crewcli": "future-name",
  "crewent": "future-name"
}
```

private automationで新coordinateの所有権、exact source authorization、3 bottle、3 target canary、rollback先を閉じ、candidate draft PRを作ります。通常CIと人のreviewを通した明示mergeまでstable Formulaを変更しません。旧commandの削除は2件以上のlive release後に別PRとcanaryで扱います。
