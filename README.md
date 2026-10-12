# homebrew-crewcli

Crewent CLIのprivate Homebrew Tapである。provider-neutralなrelease manifestを入力に、決定的なFormula候補を生成する。source repositoryのrelease producer、Tap adapter、GHCR bottle、consumer canaryを分離し、名称変更後も`phase2-cli` release identityと旧immutable artifactを保持する。Tap repository名と内部schema名は互換性のため`crewcli`を維持する。

## 現在の状態

2026-10-12時点ではPre-Activationである。parser、Formula renderer、source fallback拒否、current/alternate name fixture、exact Immutable Release manifest import、3 target bottle build/publish contract、4環境consumer canary、stable promotion PR contractは実装済みである。Distribution Reader credentialは設定済みだが、source Release、private GHCR bottle、platform別credential、Windows 11 + WSL2 runner、実canaryは未実行であり、employee向け提供は開始していない。

## 検証

```sh
ruby -Itest test/distribution_manifest_test.rb
ruby -Itest test/formula_renderer_test.rb
ruby -Itest test/formula_renames_test.rb
ruby -Itest test/import_release_test.rb
ruby -Itest test/release_asset_test.rb
ruby -Itest test/import_manifest_workflow_test.rb
ruby -Itest test/verify_activation_window_test.rb
ruby -Itest test/verify_release_bundle_test.rb
ruby -Itest test/assert_bottle_matrix_test.rb
ruby -Itest test/bottle_workflow_test.rb
ruby -Itest test/assert_canary_matrix_test.rb
ruby -Itest test/canary_workflow_test.rb
ruby -Itest test/promotion_workflow_test.rb
ruby scripts/import_release.rb check \
  --config config/distribution.json \
  --manifest test/fixtures/crewcli.distribution-release.v1.json \
  --output Formula/crewent.rb
brew style Formula/crewent.rb
brew audit --formula --strict zoe-llc/crewcli/crewent
```

`import_release.rb`はlocal file以外を読まず、GitHub Appやnetwork credentialを所有しない。
manual import workflowはexact SemVerからimmutable `cli-v<version>` releaseを解決し、read-only
installation tokenで`distribution-release.json`だけをdownloadしてFormula候補を検証する。
stable Formulaのcommitやpromotionは行わない。

認証境界と利用者手順は[Private Tap access](docs/operations/private-access.md)、4環境の実行手順は[canaryとpromotion](docs/operations/canary-and-promotion.md)、復旧は[Rollback](docs/operations/rollback.md)を参照する。現在の実Activation判定は[consumer activation evidence](docs/verification/consumer-activation.md)にある。
