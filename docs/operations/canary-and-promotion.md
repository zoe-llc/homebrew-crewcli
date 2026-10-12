# 4環境canaryとstable promotion

## 状態

workflowとfail-closed evidence contractは実装済みである。実行にはexact source Release、3 bottle、
専用Hosted Product / Change Intent、platform別credential、Windows 11 + WSL2 runner、実行時間を含む
source authorization recordが必要である。1つでも欠ける間はcanaryをdispatchせず、stable Formulaを
変更しない。

## 固定する対象

`Verify exact private Homebrew consumers`へ次を一組として渡す。

- version、source SHA、authorization SHA
- 成功したbottle workflow run ID
- production deploy SHAとquery/pathのないHTTPS origin
- 専用Product slug、Product-scoped Change Intent Number
- `zoe-llc/cli-distribution-canary`のcleanなexact commit SHA

workflowはbottle runのActions API recordを先に読み、workflow path、`workflow_dispatch`、`main`、
completed/successを検査する。artifact取得後はcandidateに閉じたrun ID、run attempt、workflow head SHAも
API recordと照合し、別workflowや再実行由来のartifactを拒否する。その上で`release-inputs`と
`bottle-candidate`からcandidate Formula、manifest、artifact、3 bottle digestを再計算する。source
harnessは`CLI Distribution Reader`でsource SHAのtarballを取得して実行する。Tap側へsourceのwrite
credentialは置かない。

## platform別secret

suffixは`MACOS_ARM64`、`LINUX_X86_64`、`LINUX_ARM64`、`WINDOWS_WSL2`の4つである。各suffixに
次をrepository secretとして設定する。値をworkflow input、artifact、log、Formulaへ入れない。

| prefix | credential | 権限 |
| --- | --- | --- |
| `CLI_TAP_READ_USER_` / `CLI_TAP_READ_TOKEN_` | private Tap Git read | `zoe-llc/homebrew-crewcli` Contents readだけのfine-grained token |
| `CLI_GHCR_READ_USER_` / `CLI_GHCR_READ_TOKEN_` | private bottle read | GHCR `read:packages`だけのclassic PAT |
| `CLI_CANARY_READ_USER_` / `CLI_CANARY_READ_TOKEN_` | canary Git/API read | `zoe-llc/cli-distribution-canary` Contents readだけのfine-grained token |
| `CLI_RUNTIME_TOKEN_` | Crewent runtime | 対象canary userの短命access token。GitHub credentialと共有しない |

Readerの3 secretは既存の
`CLI_DISTRIBUTION_READER_APP_ID`、`CLI_DISTRIBUTION_READER_APP_PRIVATE_KEY`、
`CLI_DISTRIBUTION_READER_APP_INSTALLATION_ID`を使う。

## runner

macOS ARM64、Linux x86_64、Linux ARM64は固定GitHub-hosted labelを使う。Windows consumerは
Windows 11上のWSL2内にrunner serviceを置き、次のlabelをすべて付ける。

```text
self-hosted,windows,x64,wsl2,cli-wsl2-canary
```

runnerはcanary専用のclean consumerとし、事前の`crewent` install、Tap、Contextを残さない。
workflowはlabelを証拠にせず、各jobでkernelとCPU architectureを実測する。WSL2はLinux kernel releaseの
`microsoft-standard-WSL2`と`powershell.exe`から取得したWindows build 22000以上を両方要求する。
このattestationがclosed lifecycle evidenceと一致しない場合はmatrixを作らない。workflowの最後にも
uninstall / untapするが、失敗後はownerがrunnerを再imageしてから再実行する。

## A/BからCへの手動境界

1. exact dispatchを行う。4 jobはprivate Tap認証、private GHCR bottle install、`--version`、`--help`、
   compatibility aliasを検証する。A/Bの直前にReader Appでauthorization SHA上の承認recordと現在の
   `develop` ancestryを取り直し、承認窓内の場合だけHosted loginとA/Bを実行する。
2. `canary-ab-<target>` artifactが4件揃い、同じSession / handoff pinであることを確認する。
3. source authorization window内で、専用Productに新しいPublished Revisionを正規操作で公開する。
   D1 rowを直接変更しない。
4. `zoe-llc/cli-distribution-canary`のdispatch時canary SHAへ、次のlightweight tagを作る。

   ```text
   cli-canary-stale-ready-<GitHub Actions run ID>
   ```

5. jobはtagがexact canary SHAを指すことだけを最大60分待つ。Cの直前にも承認recordとancestryを
   取り直し、承認窓内の場合だけCのexit 3 / stale no-rebindを確認する。
6. 各platformでupgrade、uninstall、reinstall、初回rollback（clean uninstall）を行う。
7. 4件すべてfresh PASSの場合だけ`canary-evidence` artifactが生成される。N/A、missing、stale、identity
   driftはmatrixにならない。

## promotion

`Open exact stable promotion pull request`へversion、source / authorization SHA、bottle run ID、canary run
IDを渡す。workflowはbottle / canary両runのpath、event、branch、success、head SHA、attemptをActions API
recordと照合し、candidate Formula hashとfresh 4環境matrixを再検証し、source authorizationをcontent
write直前に再確認する。その後だけ書込credentialを一時的に注入してpromotion branchをpushする。

`GITHUB_TOKEN`によるpushでは通常のpush/PR triggerが抑止されるため、workflowはpushしたexact commitへ
`validate.yml`を明示dispatchし、同じhead SHAのrunがsuccessになるまで待つ。成功後にだけ日本語PRを作る。
checkout時やFormula / evidence検証中にwrite credentialをGit設定へ保存しない。

workflowはPRをmergeしない。CIと差分を確認して人がmergeするまでstable Formulaは変わらない。
npm publish / dist-tag、source Release、tag、GHCR blobは変更しない。

## 失敗時

- A/B前の失敗: credential scope、candidate identity、runner cleanlinessを境界ごとに確認する。
- A/B後の失敗: raw outputを保存せず、run URLとsanitized failureだけを残す。stale-ready tagは再利用しない。
- Cまたはlifecycle失敗: promotionしない。candidate installを削除し、必要ならrunnerを再imageする。
- promotion失敗: branch / PRが作られる前なら再承認後に新run、作成後ならPRをcloseして新runを使う。

rollbackは[Rollback](rollback.md)に従い、Release assetやbottleを削除しない。
