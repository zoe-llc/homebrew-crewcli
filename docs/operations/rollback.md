# Rollback

## 不変条件

- GitHub Release asset、source tag、GHCR bottleを削除、上書き、再利用しない。
- stable Formulaの変更は通常PR、blocking CI、exact repository approval recordを通す。現行GitHub Freeではprotected environmentを前提にせず、将来Enterpriseへ移行した後に`stable-promotion` environmentを追加する。
- rollback先は同じmanifest、Formula commit、3 bottle digest、4環境canaryがすべてPASSした直前versionに限る。
- npm dist-tagやnpm packageは変更しない。

## 初回提供前または初回canary失敗

stable Formulaを提供状態へ進めない。端末上の候補を`brew uninstall crewcli`で削除し、必要なら`brew untap zoe-llc/crewcli`する。まだ直前stableがないため、rollback pointは「未提供状態」である。

## 2版目以降

1. 現在のFormula commit、manifest version、3 bottle digest、失敗したcanary evidenceを記録する。
2. 直前verified Formulaの内容を新しいrollback PRとして復元する。履歴を書き換えない。
3. CI green後、exact version、Formula commit、3 bottle digest、4環境canary、rollback ownerをrepository approval recordへ固定し、承認済みcommitからPRをmergeする。
4. macOS ARM64、Linux x86_64、Linux ARM64、Windows 11 + WSL2で次を実行する。

```sh
brew update
brew reinstall zoe-llc/crewcli/crewcli
crewcli --version
crewcli --help
```

5. runtime A/B/Cとuninstall/reinstallを再確認し、4環境が揃った時点だけrollback完了とする。

一部環境だけをpromoteまたはrollbackしてはならない。bottle欠落やdigest driftがある場合はsource fallbackへ切り替えず、stableを直前verified commitへ戻す。
