# homebrew-crewcli

Crewent CLIのprivate Homebrew Tapである。provider-neutralなrelease manifestを入力に、決定的なFormula候補を生成する。source repositoryのrelease producer、Tap adapter、GHCR bottle、consumer canaryを分離し、名称変更後も`phase2-cli` release identityと旧immutable artifactを保持する。Tap repository名と内部schema名は互換性のため`crewcli`を維持する。

## 現在の状態

2026-10-12時点ではPre-Activationである。parser、Formula renderer、source fallback拒否、current/alternate name fixtureは実装済みだが、private GHCR bottleと4環境canaryは未作成であり、employee向け提供は開始していない。

## 検証

```sh
ruby -Itest test/distribution_manifest_test.rb
ruby -Itest test/formula_renderer_test.rb
ruby -Itest test/formula_renames_test.rb
ruby -Itest test/import_release_test.rb
ruby scripts/import_release.rb check \
  --config config/distribution.json \
  --manifest test/fixtures/crewcli.distribution-release.v1.json \
  --output Formula/crewent.rb
brew style Formula/crewent.rb
brew audit --formula --strict zoe-llc/crewcli/crewent
```

`import_release.rb`はlocal file以外を読まず、GitHub Appやnetwork credentialを所有しない。live manifest downloadは外部Activation gate後のworkflowが担当する。

認証境界と利用者手順は[Private Tap access](docs/operations/private-access.md)、復旧は[Rollback](docs/operations/rollback.md)を参照する。
