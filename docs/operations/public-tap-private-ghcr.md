# Public Tap / private GHCR access

## 現在の状態

この手順はInternal Activation後のemployee向け契約である。2026-10-17時点ではTapはまだprivateで、GHCR packageとbottleは0件、Gate Cも`BLOCKED`のため、まだインストールを実行しない。

Activation後はTap `zoe-llc/homebrew-crewcli`をpublic metadataとして匿名取得し、bottle payload `ghcr.io/zoe-llc/crewcli/crewent`だけをprivateに保つ。public TapはCrewent CLIの一般公開、source repositoryやRelease assetの公開、OSS化、公開ライセンス付与を意味しない。

認証は一つの万能tokenへ集約しない。Tap readは匿名、GHCR read、manifest read、Crewent runtime loginは別境界である。npm account、npm token、npm Teamsは使わない。CIのdistribution canaryもGHCR用2 secretだけを使い、社員用credential、bottle read-back credential、runtime credentialと共有しない。

## 1. public Tapを匿名取得する

Tap credentialを設定せず、通常の1引数形式を使う。

```sh
brew tap zoe-llc/crewcli
```

この操作でGitHub username、PAT、SSH key、Authorization header、credential入りURLを使わない。匿名tapが失敗した場合はprivate cloneやsource buildへfallbackせず、Tap visibility、repository ID `1414534332`、default branch `main`、GitHub availabilityを確認して停止する。

非公式TapのFormulaは実行可能なRubyである。whole Tapを暗黙にtrustせず、組織の手順で確認した対象Formulaだけをtrustする。

```sh
brew trust --formula zoe-llc/crewcli/crewent
```

参照: [Homebrew Taps](https://docs.brew.sh/Taps.html)、[Tap Trust](https://docs.brew.sh/Tap-Trust)

## 2. private GHCR bottleだけを認証して読む

GHCR package側で利用者または配布teamに`Read`を付与する。個人端末のcredentialは`read:packages`だけを持つ期限付きpersonal access token (classic)とし、OrganizationがSAML SSOを使う場合は同Organizationへauthorizeする。

承認済みsecret managerからinstall / upgrade processのenvironmentへ次の2値を注入する。値をコマンド引数、shell history、shell profile、Git config、Homebrew config、Tap file、ログへ書かない。

- `GITHUB_USER`: token ownerのGitHub username
- `GHCR_READ_PAT`: `read:packages`だけを持つclassic PAT

次のコマンドは値がすでにprocess environmentへ安全に注入されている場合だけ実行する。Basic authorization値をprocess内で作り、成功・失敗にかかわらず同じshellで破棄する。

```sh
test -n "${GITHUB_USER:-}"
test -n "${GHCR_READ_PAT:-}"
registry_auth="$(printf '%s:%s' "$GITHUB_USER" "$GHCR_READ_PAT" | base64 | tr -d '\r\n')"
export HOMEBREW_DOCKER_REGISTRY_BASIC_AUTH_TOKEN="$registry_auth"
brew install --force-bottle zoe-llc/crewcli/crewent
unset HOMEBREW_DOCKER_REGISTRY_BASIC_AUTH_TOKEN GHCR_READ_PAT registry_auth
```

Formulaはbottleがない場合のconsumer source fallbackを停止する。`brew install --build-from-source`は利用者向け経路ではない。bottle build workflowだけが一時的な`HOMEBREW_CLI_DISTRIBUTION_BOTTLE_BUILD=1`を使用できる。

認証失敗時はtoken scopeを広げず、packageのprivate visibility、明示的Read grant、classic PATの期限、`read:packages` exact scope、必要時のSSO authorizationを境界ごとに確認する。anonymous GHCR pullが成功した場合は公開事故としてGate #5をFAILにし、認証付きinstallを続行しない。

参照: [GitHub Container registry authentication](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)、[PATのSSO authorization](https://docs.github.com/authentication/authenticating-with-saml-single-sign-on/authorizing-a-personal-access-token-for-use-with-saml-single-sign-on)、[package access control](https://docs.github.com/en/enterprise-cloud%40latest/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)

## 3. manifest readはmanual CIだけに限定する

`Crewent Distribution Reader` GitHub App installation tokenはTapのmanual import / bottle / promotion workflowだけがprivate sourceを読むために使う。権限はsource repository `zoe-llc/crewent`の`Contents: read`だけとし、public pull request、利用者端末、Formula、release evidence、GHCR credentialへ渡さない。

source側のexact scope verifyと3件のrepository secret同期が完了した状態を維持する。workflowはexact `cli-v<version>` Immutable Release、App slug、installation ID、manifest asset URLをfail-closedで検証する。repository contents APIの任意path、source fallback、import workflowからのFormula commit、stable auto-mergeは行わない。

## 4. runtimeへloginする

インストール後の`crewent login`はproduct runtime credentialを作る。これは匿名Tap read、GHCR read、GitHub Appのどれとも共有しない。移行期間は`crewcli` commandも同じentry pointへの互換aliasとして提供する。

Homebrew distribution canaryはloginやruntime APIを実行せず、runtime credentialを受け取らない。Hosted、Product、Change Intent、Context Handoffを確認する製品canaryはsource repositoryが独立して所有する。配布側のsecret名と実行手順は[3環境distribution canaryとstable promotion](canary-and-promotion.md)を参照する。

## 更新と削除

upgradeでもTapは匿名、private bottleだけを同じprocess-local GHCR credentialで読む。

```sh
brew update
test -n "${GITHUB_USER:-}"
test -n "${GHCR_READ_PAT:-}"
registry_auth="$(printf '%s:%s' "$GITHUB_USER" "$GHCR_READ_PAT" | base64 | tr -d '\r\n')"
export HOMEBREW_DOCKER_REGISTRY_BASIC_AUTH_TOKEN="$registry_auth"
brew upgrade zoe-llc/crewcli/crewent
unset HOMEBREW_DOCKER_REGISTRY_BASIC_AUTH_TOKEN GHCR_READ_PAT registry_auth
brew list --formula crewent
brew uninstall crewent
brew untap zoe-llc/crewcli
```

旧`crewcli` Formulaを導入済みの端末では、rootの`formula_renames.json`が`crewcli`から`crewent`への直接renameを表す。旧Formulaを併存させず、新しい正式名をupgrade対象にする。

## 管理者の停止条件

- TapのPhase A監査が未完了、または公開対象に未裁定materialがある間はpublicへ変更しない。
- public化windowではRelease、tag、package、bottle、canary、promotionを作らない。
- public化後にrepository ID、exact main SHA、anonymous clone、protection / Actions policyが一致しなければReleaseへ進まない。
- 初回package publish前にOrganizationの`Inherit access from source repository`を無効化する。
- package publish後にprivate visibility、Tap link、permission非継承、anonymous rejection、approved reader successを一つでも証明できなければpromotionへ進まない。
- public Tapをprivateへ戻しても、公開済みhistory、Actions log、fork、cacheを回収したとは扱わない。
