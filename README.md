# homebrew-crewent

Crewent CLI の Formula-only Homebrew Tap です。Formula と credential-free な検証 metadata を匿名で配布し、bottle payload は private GHCR に保持します。Tap の公開は Crewent source、Release asset、CLI 自体の一般公開、OSS 化、公開ライセンス付与を意味しません。

## 現在の状態

2026-10-17 時点では repository ID `1414534332` を維持した public Formula-only Tap として準備済みです。Release、tag、GHCR package、実 canary、stable Formula promotion は実施していません。

tracked code が保持する実行面は secret-free な `.github/workflows/validate.yml` だけで、repository secret は 0 件です。次の capability は private [`zoe-llc/crewent-distribution`](https://github.com/zoe-llc/crewent-distribution) が所有します。

- private source Release の読み取り
- 3 target bottle の build と private GHCR publish
- public Tap candidate の draft PR 作成
- macOS ARM64、Linux x86_64、Linux ARM64 の distribution canary
- final activation evidence の検証と draft PR の更新

public化後の Tap は repository secret、package permission、protected Actions artifact、private App key、GHCR credential、mutation workflow を持ちません。stable Formula PR の merge は自動化しません。

## ローカル検証

```sh
find test Formula -name '*.rb' -print0 | xargs -0 -n1 ruby -c
for test_file in test/*_test.rb; do ruby -Itest "$test_file"; done
actionlint
! rg -n 'secrets\.|packages:|upload-artifact|download-artifact|pull_request_target' .github/workflows
git diff --check
```

認証境界と将来の利用手順は [Public Tap / private GHCR access](docs/operations/public-tap-private-ghcr.md)、canary と promotion の所有権は [運用手順](docs/operations/canary-and-promotion.md)、復旧は [Rollback](docs/operations/rollback.md) を参照してください。実 Activation の未達条件は [consumer activation evidence](docs/verification/consumer-activation.md) にあります。
