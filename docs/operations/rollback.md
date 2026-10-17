# Rollback

## 不変条件

- GitHub Release asset、source tag、GHCR bottleを削除、上書き、再利用しない。
- stable Formulaの変更は通常PR、blocking CI、exact source authorizationを通す。
- rollback先は同じmanifest、Formula commit、3 bottle digest、3環境distribution canaryがすべてPASSした
  直前versionに限る。
- npm dist-tagやnpm packageは変更しない。
- promotion / rollback workflowはPRを自動mergeしない。
- source側の製品canaryをdistribution evidenceで代替しない。

## 初回提供前または初回canary失敗

stable Formulaを提供状態へ進めない。端末上の候補を`brew uninstall crewent`で削除し、必要なら
`brew untap zoe-llc/crewent`する。まだ直前stableがないため、rollback pointは「未提供状態」である。

## 2版目以降

1. 現在のFormula commit、manifest version、3 bottle digest、失敗したdistribution evidenceを記録する。
2. 直前verified Formulaの内容を新しいrollback PRとして復元する。履歴を書き換えない。
3. CI green後、exact version、Formula commit、3 bottle digest、3 target evidence、rollback ownerを記録し、
   承認済みcommitからPRをmergeする。
4. macOS ARM64、Linux x86_64、Linux ARM64で次を実行する。

```sh
brew update
brew reinstall zoe-llc/crewent/crewent
crewent --version
crewent --help
crewent --version
```

5. uninstall、reinstall、clean rollbackを再確認し、3環境が揃った時点で配布rollbackを完了とする。
6. 総合提供判定では、同じrelease identityを参照するsource側の製品canaryも別gateとして確認する。

一部環境だけをpromoteまたはrollbackしてはならない。bottle欠落やdigest driftがある場合はsource fallbackへ
切り替えず、stableを直前verified commitへ戻す。

実行中の候補で失敗した場合は、`brew uninstall crewent`と`brew untap zoe-llc/crewent`でcleanな
未提供状態へ戻す。失敗runのevidenceを次のrunへ流用せず、新しいbottle / distribution canary run IDと
source authorizationを使う。

Windows / WSL2は未検証であり、現時点のblocking rollback targetには含めない。将来対応する場合は独立した
compatibility workflowの結果として扱う。
