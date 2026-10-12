# Crewent 0.1.0 bottle build evidence

## Status

`BLOCKED — workflow implementation only`

この文書は3 target bottleのlive成功証拠ではない。`Build and publish exact bottles` workflowとclosed matrix parserは実装済みだが、source `cli-v0.1.0` Immutable Release、exact Activation record、Windows 11 + WSL2 consumer runnerがまだ存在しないため、workflowをdispatchしていない。

## Fixed identity

| Field | Required value |
| --- | --- |
| Source repository | `zoe-llc/crewcli` |
| Tap repository | `zoe-llc/homebrew-crewcli` |
| Release identity | `phase2-cli` |
| Version | `0.1.0` |
| Formula | `crewent` |
| GHCR root | `https://ghcr.io/v2/zoe-llc/crewcli` |
| Targets | `macos-arm64`, `linux-x86_64`, `linux-arm64` |

## PASSに必要なread-back

- source Releaseが`immutable: true`で、exact six-asset set、source SHA、authorization SHA、全payload digestが一致する。
- `macos-15`、`ubuntu-24.04`、`ubuntu-24.04-arm`が同じmanifestとFormula bytesからbottleを生成する。
- 各targetで`brew install --build-bottle`、`brew test`、`crewent --version`、`crewent --help`、`crewcli --version`が成功する。
- 3件のbottle JSON、archive SHA-256、OCI index/child manifest、読取専用consumerによるGHCR blob read-backが揃い、`scripts/assert_bottle_matrix.rb`と`scripts/assert_ghcr_readback.rb`がPASSする。
- Formula candidateはreview artifactとして保持し、このworkflowからstable Formulaをpushまたはmergeしない。
- GHCR package `crewcli/crewent`をTap repositoryへlinkし、publish jobだけWrite、consumerは期限付き`read:packages`だけのclassic PATと必要時SSOに限定したことをread backする。workflow secretsは`GHCR_READ_USER`と`GHCR_READ_PAT`を使用する。

## Failure policy

一targetの欠落、重複、architecture/tag drift、digest不一致、mutable registry reference、npm registry access、source fallback、partial uploadでは全体をFAILにする。失敗したversionのartifactを置換せず、新しい承認windowで再実行する。
