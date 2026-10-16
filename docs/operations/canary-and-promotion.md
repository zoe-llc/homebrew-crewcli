# 3環境 distribution canary と stable promotion

## 所有権と状態

canary と promotion workflow の正本は private [`zoe-llc/crewcli-distribution`](https://github.com/zoe-llc/crewcli-distribution) です。public Tap は workflow、secret、private artifact、package permission を持ちません。

2026-10-17 時点では workflow 契約だけが準備済みです。Tap は private のままで、旧source Reader secret 3件もsettingsに残っています。source Release、private GHCR bottle、candidate PR、実 canary、stable promotion は未実行です。secret削除とautomation側へのcredential設定は、別の明示承認まで行いません。

## candidate と canary

private automation の promotion `stage` は exact version / source SHA / authorization SHA / bottle run ID を検証し、candidate Formula と credential-free bottle metadata だけを Tap の candidate branch へ commitして draft PR を作ります。stable `main` を直接変更せず、PR を merge しません。

canary は draft PR number と exact 40-hex head SHA を追加で受け取り、次の3 targetを検証します。

| target | runner |
| --- | --- |
| `macos-arm64` | `macos-15` |
| `linux-x86_64` | `ubuntu-24.04` |
| `linux-arm64` | `ubuntu-24.04-arm` |

各 runner は `GH_TOKEN`、`GITHUB_TOKEN`、`HOMEBREW_GITHUB_API_TOKEN` と GitHub Authorization extraheader がない状態で public Tap candidate SHA を `--no-tags` cloneします。Formula digest一致後の private bottle install stepだけが `CLI_GHCR_READ_USER` / `CLI_GHCR_READ_TOKEN` を受け取り、install、command、uninstall、reinstall、clean rollbackを閉じます。

## final evidence と stable PR

promotion `finalize` は exact bottle run、distribution canary run、draft PR / head SHA、3 target matrixを再検証します。source Reader Appは source `Contents: read`だけ、Tap Publisher Appは Tap candidate branchとPRだけに限定します。全10 Gateが `PASS` の final activation windowを検証した場合だけ、credential-free evidenceを同じ draft branchへ追加します。

workflowは draft PRをready化またはmergeしません。stable Formulaは、人が差分・CI・activation evidenceを確認して通常のPR mergeを明示実施するまで変わりません。

## 失敗時

- 別 run、別 candidate、別 SHA のartifactで代替しない。
- credential付き Tap clone、public GHCR、consumer source buildへfallbackしない。
- 一targetでも失敗したら新しい run IDで3 targetすべてを再実行する。
- draft PR作成後に identity が変わった場合は既存PRを閉じ、新しい candidateからやり直す。

rollbackは [Rollback](rollback.md) に従い、Release assetやbottleを削除しません。
