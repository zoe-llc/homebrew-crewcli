# Public Tap / private GHCR consumer activation evidence

## 判定

2026-10-17時点: **実装 PASS / 実Activation BLOCKED**。

## 実装済み

- exact bottle candidate metadata（candidate Formula、source Formula、manifest、artifact、matrix digest）
- bottle / distribution canary producer runのworkflow path、event、branch、head SHA、attempt、success照合
- macOS ARM64、Linux x86_64、Linux ARM64の固定3環境workflow
- 実OS / CPU architectureのattestation
- public Tapのanonymous repository API read-back、token環境 / credential helperを無効化したexact detached clone
- private GHCR readを`CLI_GHCR_READ_USER` / `CLI_GHCR_READ_TOKEN`の2件だけへ限定したcredential境界
- bottle read-back用`GHCR_READ_USER` / `GHCR_READ_PAT`との用途分離
- private GHCRのauthenticated session logout後にexact version / digestのanonymous pullを拒否するclosed evidence
- anonymous Tap + authenticated private GHCR、`--force-bottle`によるsource fallback拒否
- primary command、help、compatibility alias、uninstall、reinstall、clean rollback
- missing / duplicate / N/A / stale / identity drift / sensitive dataを拒否するclosed matrix
- read-only検証jobとwrite jobを分離し、exact source authorizationをwrite直前に再検証するpromotion
- exact promotion commitの`validate.yml`成功後だけstable promotion PRを作り、自動mergeしないworkflow
- public PR validationを`contents: read`だけにし、manual mutation、package、repository secret、App keyから分離する横断policy test

Homebrew側はCrewent製品canaryを実行しない。Hosted、Product、Change Intent、Context Handoff、A/B/C、
stale no-rebindはsource repositoryの独立gateである。distribution PASSは製品PASSを意味しない。

ローカル証拠:

```sh
ruby -Itest test/assert_canary_matrix_test.rb
ruby -Itest test/canary_workflow_test.rb
ruby -Itest test/promotion_workflow_test.rb
ruby -Itest test/assert_ghcr_readback_test.rb
ruby -Itest test/bottle_workflow_test.rb
ruby -Itest test/rename_rehearsal_test.rb
ruby -Itest test/public_repository_policy_test.rb
actionlint .github/workflows/bottle.yml .github/workflows/canary.yml .github/workflows/promote.yml
```

## 未実行の外部gate

- Tap全履歴・Actions log / artifact・issue / PR・author metadataのPhase A監査
- repository ID `1414534332`を維持したpublic visibility変更、anonymous clone、protection / Actions read-back
- Organization package permission inheritance無効化
- exact source Immutable Releaseと3 private GHCR bottles
- bottle read-back用`GHCR_READ_USER` / `GHCR_READ_PAT`
- distribution canary用`CLI_GHCR_READ_USER` / `CLI_GHCR_READ_TOKEN`
- private package visibility、Tap link、permission非継承、anonymous pull拒否、approved reader成功
- exact dispatch対象と実施時間を固定したsource authorization window
- 3環境の実workflow runと`distribution-canary-evidence` artifact
- promotion PRのCI、review、merge

これらをローカルtestでPASSとみなさない。実run ID、exact identity、artifact URLは実行後に本書へ追記する。

Windows 11 + WSL2は初回blocking targetではなく未検証である。独立compatibility workflowによる証拠が
できるまでWindows対応済みとは表示しない。
