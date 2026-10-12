# Private Homebrew consumer activation evidence

## 判定

2026-10-12時点: **実装 PASS / 実Activation BLOCKED**。

## 実装済み

- exact bottle candidate metadata（candidate Formula、source Formula、manifest、artifact、matrix digest）
- bottle / canary producer runのworkflow path、event、branch、head SHA、attempt、success照合
- macOS ARM64、Linux x86_64、Linux ARM64、Windows 11 + WSL2の固定4環境workflow
- kernel、CPU、Windows buildによる実platform attestation（self-hosted labelだけを証拠にしない）
- Tap Git read、GHCR read、canary Git read、runtime tokenの分離
- exact source SHAのStep 3 A/B/C harness
- A/B直前とC直前に現在のsource authorization window / ancestryを再取得して検証
- stale-ready tagを介したHosted公開操作との手動境界
- upgrade、uninstall、reinstall、初回rollback
- missing / duplicate / N/A / stale / identity drift / sensitive dataを拒否するclosed matrix
- 4 fresh PASS後にexact promotion commitの`validate.yml`成功を待ち、stable promotion PRだけを作って
  自動mergeしないworkflow

ローカル証拠:

```sh
ruby -Itest test/assert_canary_matrix_test.rb
ruby -Itest test/canary_workflow_test.rb
ruby -Itest test/promotion_workflow_test.rb
ruby -Itest test/bottle_workflow_test.rb
actionlint .github/workflows/bottle.yml .github/workflows/canary.yml .github/workflows/promote.yml
```

## 未実行の外部gate

- exact source Immutable Releaseと3 private GHCR bottles
- 4 suffix分のTap / GHCR / canary / runtime credential
- Windows 11 + WSL2 self-hosted runner
- productionの専用Product / Change Intentと公開前後のRevision
- exact dispatch対象と実施時間を固定したsource authorization window
- 4環境の実workflow runと`canary-evidence` artifact
- promotion PRのCI、review、merge

これらをローカルtestでPASSとみなさない。実run ID、exact identity、artifact URLは実行後に本書へ追記する。
