# 3環境distribution canaryとstable promotion

## 状態

workflowとfail-closed evidence contractは実装済みである。実行にはpublic TapのPhase A / B証拠、
exact source Release、private GHCRの3 bottle、distribution canary用GHCR read credential 2件、
実行時間を含むsource authorization recordが必要である。1つでも欠ける間は
canaryをdispatchせず、stable Formulaを変更しない。

このworkflowはpublic Tap metadata + private GHCR bottleのHomebrew配布だけを検証する。Hosted、Product、Change Intent、Context Handoff、
A/B/C、stale no-rebindはsource repositoryの製品canaryが独立して検証する。distribution canaryのPASSを
製品canaryのPASSとして扱わない。

## distribution canary

`Verify exact public Tap and private GHCR distribution`へ次の4値を一組として渡す。

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

各jobは実OS / architectureを`uname`で確認し、repository ID `1414534332`、public visibility、default branchを
Authorization headerなしでread backする。GitHub token環境とcredential helperを無効化してpublic Tapを
`--no-tags` cloneし、detached exact workflow SHA、remote URL、Formula digestを確認する。candidate Formulaを
Tapへ配置し、認証済みprivate GHCRから`--force-bottle`でinstallする。primary command、help、
compatibility alias、uninstall、reinstall、clean rollbackを確認する。source buildやpublic registryへ
fallbackしない。

3件すべてが2時間以内のfresh PASSで、同じcandidate / producer / workflow identityを持つ場合だけ
`distribution-canary-evidence` artifactを生成する。missing、duplicate、N/A、identity drift、secret様文字列は
closed schemaが拒否する。

## distribution canary read secret

distribution canaryは次の2 repository secretだけを使う。Tap read credential、OS別suffix、runtime token、
canary repository token、Distribution Reader App token、bottle read-back credentialは渡さない。

| secret | 用途 | 最小権限 |
| --- | --- | --- |
| `CLI_GHCR_READ_USER` | private GHCR Basic authのusername | 値自体は権限を持たない |
| `CLI_GHCR_READ_TOKEN` | exact bottle pull | `read:packages` |

credentialはnetwork operationのstepだけへ注入し、URL、Formula、artifact、evidenceへ保存しない。
CI用credentialを社員端末へ配布しない。

bottle publish後の独立read-backは`GHCR_READ_USER` / `GHCR_READ_PAT`を使う。authenticated ORAS sessionを
logoutしてcredential entry不在を確認した後、exact version tagとdigestの匿名manifest取得が両方失敗する
ことを`crewcli.ghcr-anonymous-pull/v1`へ記録する。その後に別consumer credentialで3 bottle blobを読み、
digestを照合する。anonymous pullが一件でも成功した場合はGate #5をFAILにして後続canaryを開始しない。

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
- consumer失敗: Tapのpublic visibility / anonymous access、private GHCR credential、実platformを別々に確認し、credential付きTap clone、public registry、source fallbackへ切り替えない。
- matrix失敗: missing target、freshness、identity driftを修正し、新しいrun IDで全3件を再実行する。
- promotion失敗: PR作成前なら再承認後に新runを使う。PR作成後ならそのPRをcloseし、新しいrunから作り直す。

rollbackは[Rollback](rollback.md)に従い、Release assetやbottleを削除しない。
