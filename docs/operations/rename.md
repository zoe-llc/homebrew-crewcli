# Homebrew配布名称変更runbook

## 目的と現在地

このrunbookは、Crewent CLIを将来別名称へ変更するときに、旧Formula、bottle、release historyを保持した
まま新名称へ移行する順序を固定する。2026-10-12時点のstable候補はFormula `crewent`、Tap
`zoe-llc/crewcli`、GHCR root `ghcr.io/zoe-llc/crewcli`である。`formula_renames.json`には既に
`crewcli`から`crewent`への互換mappingがある。

本書と`test/rename_rehearsal_test.rb`は一時fixtureだけを使う。**実名称変更、repository rename、GHCR
publish、Formula promotionは行わない。** 実行にはsource側の
[CLI配布名称変更runbook](https://github.com/zoe-llc/crewcli/blob/develop/docs/operations/cli-distribution-rename.md)
に定める別の明示承認windowが必要である。

## 不変条件

- stable release identity `phase2-cli`、既存SemVer、source SHA、manifest SHA-256を変えない。
- 旧GitHub Releaseのtag / asset / manifestと旧GHCR bottle digestを上書き・削除しない。
- 新Formulaは新SemVerの新manifestから生成し、consumer source fallbackを許可しない。
- 直前primary commandを同じentrypointへのaliasとして最低2件のlive releaseで維持する。
- macOS ARM64、Linux x86_64、Linux ARM64の3 bottleと、Windows 11 + WSL2を含む4 consumerを
  all-or-nothingで扱う。
- Tap Git read、GHCR read、GHCR write、source Reader App、runtime credentialを共有しない。

## 開始gate

1. 新しいFormula名、Tap full name、GHCR root、primary command、npm package名を固定する。
2. 新しいrepository/package coordinateの所有権、visibility、owner、retentionをread backする。
3. exact source SHA、authorization SHA、version、実施時間、rollback先を承認recordへ閉じる。
4. 旧stable Formula、旧Tap remote、旧GHCR bottleが取得できることを確認する。
5. 3 build runner、4 consumer、platform別credential、専用Product / Change Intentを準備する。
6. employee通知、再認証、support、alias 2-release counterのownerを決める。

不足があれば旧Formulaやmappingを削除せず停止する。

## rehearsal

```sh
ruby -Itest test/rename_rehearsal_test.rb
```

testは一時directoryに旧Formula / bottle snapshotと新Formula / bottleを共存させ、次を検証する。

- 旧Formula bytes / digestと旧bottle bytes / digestが不変である。
- 新Formulaが新primary commandと直前command aliasを同じentrypointへinstallする。
- rename mappingがchainにならず、すべてのlegacy Formula名から新Formulaへ直接解決する。
- 旧snapshotが残り、直前stableへrollbackできる。

## 実行順

### 1. 新adapter設定とFormula候補を作る

`config/distribution.json`の`formulaName`、`tap`、`bottleRoot`だけを新coordinateへ変更する。source
repositoryを同時renameしない場合は`sourceRepository`を維持する。新しいsource manifestをexact inputに
`scripts/import_release.rb`で新Formulaを生成し、旧Formula fileを編集して流用しない。

### 2. Formula renameをflattenする

rootの`formula_renames.json`へ直前Formulaから新Formulaへのmappingを追加する。既存のlegacy mappingが
別のlegacy名を指している場合、chainを残さず、すべて新Formulaへ直接向ける。例えば将来
`crewent`を`future-name`へ変える場合の形は次である。

```json
{
  "crewcli": "future-name",
  "crewent": "future-name"
}
```

新Formulaのprimary / alias launcherを検証するまでこのmappingをstableへmergeしない。

### 3. 新coordinateへbottleをappendする

新FormulaからmacOS ARM64、Linux x86_64、Linux ARM64 bottleをbuildし、新GHCR rootへpublishする。
旧GHCR manifest、tag、blobをcopy、retag、deleteしない。新packageのprivate visibility、Tap repository
linkage、write jobとread-only consumerの両方をread backする。

### 4. Tap/repository trustを移行する

Tap repositoryをrenameまたは移転した場合もGitHub redirectを認証契約にしない。

- workflow内のrepository、Actions API path、checkout URL、branch/ruleset、CODEOWNERSを新full nameへ更新。
- promotion workflowのrun identity検証が新workflow pathとrepositoryを参照することを確認。
- employee端末で旧Tap repositoryのremote URLを新URLへ変更し、`brew update`後に新Formulaへ解決することを
  確認。新規利用者は新Tap名だけを使う。
- source Reader Appはsource repository IDと`Contents: read` installationをread backする。source
  repositoryも変わる場合だけ、新repositoryを明示追加してtoken canaryを再実行する。
- platform別Tap/GHCR credentialを新resourceへ最小権限で再発行し、旧access削除は移行完了後に行う。

### 5. canaryとpromotion

exact bottle workflow run、candidate metadata、4環境のruntime A/B/C、upgrade、uninstall、reinstall、
rollbackを実行する。4件のfresh PASSと再承認後にだけstable promotion PRを作り、通常CI/reviewでmergeする。
workflowから自動mergeしない。

## 利用者通知

通知には新規install command、既存Tap remote更新、`brew update && brew upgrade`、新旧command、再認証、
alias維持期間、rollback/support先を含める。旧commandは新名称でstable提供したreleaseを2件以上数え、別の
削除PRとcanaryを通すまで残す。

## rollback

- promotion前: 新Formulaをstableへ入れず、新release / bottleを不変の失敗証拠として保持する。
- promotion後: 通常PRでFormulaを直前verified snapshotへ戻し、旧Tap remote / GHCR read trustを再設定する。
- 4環境で旧versionと旧commandを再検証するまでrollback完了としない。
- 新旧のrelease、Formula履歴、bottleを削除して見かけ上元に戻さない。

新名称で公開npm packageも開始していた場合はsource側Public Activation runbookに従い、Homebrew rollbackと
npm deprecation / dist-tag rollbackを別境界として扱う。
