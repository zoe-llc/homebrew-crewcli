# Private Tap access

## 現在の状態

この手順はInternal Activation後のemployee向け契約である。2026-10-12時点ではbottleとGHCR packageが未作成で、Gate Cも`BLOCKED`のため、まだインストールを実行しない。

認証は1個の万能tokenへ集約しない。Tap Git read、GHCR read、manifest read、Crew CLI runtime loginは別の境界として扱う。npm account、npm token、npm Teamsは使わない。

## 1. private Tapを取得する

利用者のGitHub accountに`zoe-llc/homebrew-crewcli`のread権限を付与し、SSOを使うorganizationではSSH keyもSSO authorization済みにする。SSH agentで対象keyを利用可能にしてから、private repositoryを明示した2引数形式でtapする。

```sh
brew tap zoe-llc/crewcli git@github.com:zoe-llc/homebrew-crewcli.git
```

Homebrewは2引数の`brew tap <user>/<repository> <URL>`でGitが扱えるSSH URLを利用できる。非公式Tapは実行可能なRubyを含むため、whole Tapではなく対象Formulaだけをtrustする。

```sh
brew trust --formula zoe-llc/crewcli/crewent
```

参照: [Homebrew Taps](https://docs.brew.sh/Taps.html)、[Tap Trust](https://docs.brew.sh/Tap-Trust)、[GitHub SSO authentication](https://docs.github.com/en/enterprise-cloud%40latest/authentication/authenticating-with-single-sign-on)

## 2. private GHCR bottleを読む

GHCR package側で利用者または配布teamに`Read`を付与する。GitHub Container registryのprivate packageを個人端末から読むcredentialは、`read:packages`だけを持つ期限付きpersonal access token (classic)とする。organizationがSAML SSOを使う場合はtokenを同organizationへauthorizeする。

token原文を設定ファイル、Tap、shell script、ログへ保存しない。承認済みsecret managerから、そのinstall/upgrade processだけへ次の2値を渡す。

- `GITHUB_USER`: token ownerのGitHub username
- `GHCR_READ_PAT`: `read:packages`だけを持つclassic PAT

Homebrewがprivate OCI bottleへ送るBasic authorization値をprocess内で作り、処理後に破棄する。

```sh
export HOMEBREW_DOCKER_REGISTRY_BASIC_AUTH_TOKEN="$(printf '%s' "${GITHUB_USER}:${GHCR_READ_PAT}" | base64 | tr -d '\n')"
brew install zoe-llc/crewcli/crewent
unset HOMEBREW_DOCKER_REGISTRY_BASIC_AUTH_TOKEN GHCR_READ_PAT
```

Formulaはbottleがない場合のconsumer source fallbackを停止する。`brew install --build-from-source`は利用者向け経路ではなく、失敗を期待する。bottle build workflowだけが一時的な`HOMEBREW_CLI_DISTRIBUTION_BOTTLE_BUILD=1`を使用できる。

参照: [GitHub Container registry authentication](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)、[PATのSSO authorization](https://docs.github.com/authentication/authenticating-with-saml-single-sign-on/authorizing-a-personal-access-token-for-use-with-saml-single-sign-on)、[package access control](https://docs.github.com/en/enterprise-cloud%40latest/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)

## 3. manifest readはCIだけに限定する

`CLI Distribution Reader` GitHub App installation tokenはTapのimport workflowだけが使用する。権限はsource repositoryの`Contents: read`だけとし、利用者端末、Formula、release evidence、GHCR credentialへ渡さない。Task 4の`import_release.rb`はlocal manifest fileだけを入力にし、App tokenの発行やnetwork accessを持たない。

## 4. runtimeへloginする

インストール後の`crewent login`はproduct runtime credentialを作る。これはTap Git read、GHCR read、GitHub Appのどれとも共有しない。移行期間は`crewcli` commandも同じentry pointへの互換aliasとして提供する。

## 更新と削除

旧`crewcli` Formulaを導入済みの端末でも、`brew update`がrootの`formula_renames.json`にある`crewcli`から`crewent`への直接renameを読み取る。旧Formulaを併存させず、そのまま新しい正式名をupgrade対象にする。

```sh
brew update
brew upgrade zoe-llc/crewcli/crewent
brew list --formula crewent
brew uninstall crewent
brew untap zoe-llc/crewcli
```

更新もprivate GHCR read credentialをprocessへ渡した状態で実行する。認証失敗時はscopeを広げず、Tap read、package Read grant、classic PATの期限、SSO authorizationを境界ごとに確認する。
