# Crewent 0.1.0 bottle build evidence

## Status

`BLOCKED — live build not executed`

2026-10-17 時点で source `cli-v0.1.0` Release、private GHCR package、3 target bottleは存在せず、この文書はlive成功証拠ではありません。build / publish contractの正本は private `zoe-llc/crewent-distribution` へ移動しました。

## Fixed identity

| Field | Required value |
| --- | --- |
| Source repository | `zoe-llc/crewent` |
| Automation repository | `zoe-llc/crewent-distribution` |
| Tap repository | `zoe-llc/homebrew-crewent` |
| Release identity | `phase2-cli` |
| Version | `0.1.0` |
| Formula | `crewent` |
| GHCR root | `https://ghcr.io/v2/zoe-llc/crewent` |
| Targets | `macos-arm64`, `linux-x86_64`, `linux-arm64` |

## PASSに必要なread-back

- source Releaseがimmutableで、exact six-asset setと全payload digestが一致する。
- private automationの3 runnerが同じmanifest / Formula bytesからbottleを生成する。
- packageがprivateでprivate automation repositoryへlinkされ、public TapのActions accessがない。
- tag / digest双方のanonymous readがHTTP 401 + Bearer challengeで拒否される。
- approved read-only identityだけがexact digestを取得できる。
- candidate Formulaと3 target matrixがdraft Tap PR、distribution canary、final activation evidenceへ同じidentityで接続される。

Release、package、canaryを実行した後にだけ、run URL、exact SHA / digest、actor、JST時刻を追記します。
