# 3環境distribution canaryとstable promotion

## 状態

workflowとfail-closed evidence contractは実装済みである。実行にはexact source Release、3 bottle、
4件の共有read credential、実行時間を含むsource authorization recordが必要である。1つでも欠ける間は
canaryをdispatchせず、stable Formulaを変更しない。

このworkflowはprivate Homebrew配布だけを検証する。Hosted、Product、Change Intent、Context Handoff、
A/B/C、stale no-rebindはsource repositoryの製品canaryが独立して検証する。distribution canaryのPASSを
製品canaryのPASSとして扱わない。

## distribution canary

`Verify exact private Homebrew distribution`へ次の4値を一組として渡す。

- exact SemVer
- source SHA
- authorization SHA
- 成功したexact bottle workflow run ID

preflight jobはbottle runのActions API recordを先に読み、workflow path、`workflow_dispatch`、`main`、
completed / successを確認する。artifact取得後はcandidateのrun ID、attempt、head SHAをAPI recordと照合し、
candidate Formula、bottle matrix、3 bottle digestを検証する。検証済みのcredential-free artifactだけを
3 consumer jobへ渡す。

consumer targetは次の3件で固定する。

| target | runner | bottle |
| --- | --- | --- |
| `macos-arm64` | `macos-15` | `arm64_sequoia` |
| `linux-x86_64` | `ubuntu-24.04` | `x86_64_linux` |
| `linux-arm64` | `ubuntu-24.04-arm` | `arm64_linux` |

各jobは実OS / architectureを`uname`で確認し、read-only credentialでprivate Tapをcloneする。
candidate FormulaをTapへ配置し、private GHCRから`--force-bottle`でinstallする。primary command、help、
compatibility alias、uninstall、reinstall、clean rollbackを確認する。source buildやpublic registryへ
fallbackしない。

3件すべてが2時間以内のfresh PASSで、同じcandidate / producer / workflow identityを持つ場合だけ
`distribution-canary-evidence` artifactを生成する。missing、duplicate、N/A、identity drift、secret様文字列は
closed schemaが拒否する。

## 共有read secret

distribution canaryは次の4 repository secretだけを使う。OS別suffix、runtime token、canary repository
token、Distribution Reader App tokenは渡さない。

| secret | 用途 | 最小権限 |
| --- | --- | --- |
| `CLI_TAP_READ_USER` | private Tap cloneのusername | 値自体は権限を持たない |
| `CLI_TAP_READ_TOKEN` | private Tap clone | `zoe-llc/homebrew-crewcli` Contents read |
| `CLI_GHCR_READ_USER` | private GHCR Basic authのusername | 値自体は権限を持たない |
| `CLI_GHCR_READ_TOKEN` | exact bottle pull | `read:packages` |

credentialはnetwork operationのstepだけへ注入し、URL、Formula、artifact、evidenceへ保存しない。
CI用credentialを社員端末へ配布しない。

## Windows / WSL2

Windows 11 + WSL2は初回stable promotionのblocking targetではない。現在は未検証であり、Windows対応済みと
表示しない。実利用要件が生じた場合は、3 target distribution canaryや製品canaryへ混ぜず、installと
filesystem lifecycleだけを確認する独立compatibility workflowとして追加する。

## stable promotion

`Open exact stable promotion pull request`へversion、source SHA、authorization SHA、bottle run ID、
distribution canary run IDを渡す。

1. read-only `verify` jobが両runのpath、event、branch、success、head SHA、attemptをActions API recordと
   照合する。
2. candidate Formula hashと3 targetのfresh closed matrixを再計算し、元のmatrixと一致する場合だけ
   credential-free `verified-promotion` artifactを作る。
3. `promote` jobがcandidate Formula、distribution matrix、bottle candidate metadataだけをstageする。
4. content write直前にfresh `CLI Distribution Reader` installation tokenを発行し、source authorization
   recordと現在の`develop` ancestryを再検証する。
5. 一度だけpromotion branchをpushし、exact commitへ`validate.yml`を明示dispatchする。同じhead SHAの
   runがsuccessの場合だけ日本語PRを作る。

workflowはPRをmergeしない。製品canary証拠と差分を人が確認してmergeするまでstable Formulaは変わらない。
npm publish / dist-tag、source Release、tag、GHCR blobは変更しない。

## 失敗時

- preflight失敗: run identity、candidate digest、artifact retentionを確認し、別runのartifactで代替しない。
- consumer失敗: targetのTap / GHCR credentialと実platformを確認し、public/source fallbackへ切り替えない。
- matrix失敗: missing target、freshness、identity driftを修正し、新しいrun IDで全3件を再実行する。
- promotion失敗: PR作成前なら再承認後に新runを使う。PR作成後ならそのPRをcloseし、新しいrunから作り直す。

rollbackは[Rollback](rollback.md)に従い、Release assetやbottleを削除しない。
