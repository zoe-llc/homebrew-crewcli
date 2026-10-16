# Public Tap / private GHCR consumer activation evidence

## 判定

2026-10-17 時点: **準備実装 PASS / 実 Activation BLOCKED**。

## 準備済みの境界

- public Tap は `Formula/crewent.rb`、`formula_renames.json`、公開文書、secret-free `validate.yml` だけを所有する。
- workflow policy test は追加 workflow、write / package permission、secret参照、artifact transfer、mutationを拒否する。
- manual public smoke は repository ID、public visibility、default branch、exact main SHA、raw Formula digest、anonymous `git clone --no-tags`、anonymous `brew tap` を検証する。
- private source read、bottle build / publish、private GHCR read-back、candidate draft PR、3 target distribution canary、final activation検証は private `zoe-llc/crewcli-distribution` が所有する。
- Tap Publisherとsource Readerは別GitHub Appで、stable PRをworkflowからmergeしない。

ローカル証拠:

```sh
find test Formula -name '*.rb' -print0 | xargs -0 -n1 ruby -c
for test_file in test/*_test.rb; do ruby -Itest "$test_file"; done
actionlint
! rg -n 'secrets\.|packages:|upload-artifact|download-artifact|pull_request_target' .github/workflows
git diff --check
```

ローカル検証は実 Activation の代替ではありません。

## 未実行の外部 gate

- Tap 全履歴・Actions log / artifact・issue / PR・author metadata の公開前監査
- 旧source Reader repository secret 3件の削除とsecret inventory 0件のread-back
- repository ID `1414534332`を維持したpublic visibility変更とanonymous read-back
- source Immutable Release と3 target private GHCR bottle
- package permission inheritance無効化、private visibility、private automation link、public Tap access不在
- tag / digest双方のanonymous pull拒否と用途分離したapproved reader成功
- public Tap candidate draft PRとexact head SHA
- macOS ARM64、Linux x86_64、Linux ARM64の実distribution canary
- 全10 Gate `PASS` のfinal activation window
- stable Formula PRのCI、review、明示merge

これらは実 run ID、exact SHA / digest、artifact URLを取得してから別のPhase 0 evidenceへ記録します。Windows / WSL2は初回blocking targetではなく未検証です。
