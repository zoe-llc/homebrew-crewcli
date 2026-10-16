# Public Tap / private GHCR access

## 現在の状態

2026-10-17 時点では Phase 0 の準備中です。Tap `zoe-llc/homebrew-crewcli` は private のままで、Release、GHCR package、実 canary、stable promotion は未実行です。この文書の install 手順は Internal Activation 後にだけ利用します。

公開後も、Tap が匿名公開するのは Formula、rename mapping、公開可能な digest / evidence だけです。source repository、Release asset、bottle payload は公開しません。Tap の公開は OSS 化や公開ライセンス付与を意味しません。

## 所有権

public Tap は Formula-only read 面です。public化後は repository secret、package permission、protected Actions artifact、private App key、GHCR credential、mutation workflow を持ちません。唯一の workflow は secret-free な `validate.yml` です。

現在のprivate Tap settingsには旧source Reader secret 3件が残っています。tracked workflowからの参照は削除済みですが、secret自体の削除はsettings変更の別承認が必要です。0件のread-backが完了するまでpublic化しません。

private [`zoe-llc/crewcli-distribution`](https://github.com/zoe-llc/crewcli-distribution) が source manifest import、bottle build / publish、GHCR read-back、candidate draft PR、3 target canary、final promotion evidence を所有します。public Tap の `GITHUB_TOKEN` を private package や source repository へ接続しません。

## 1. public Tap を匿名取得する

Activation 後は GitHub credential を渡さず、通常の一引数形式で取得します。

```sh
brew tap zoe-llc/crewcli
brew trust --formula zoe-llc/crewcli/crewent
```

匿名 Tap が失敗した場合は private clone、credential 付き clone、source build へ fallback しません。repository ID `1414534332`、public visibility、default branch `main`、GitHub availability を確認して停止します。

## 2. private GHCR bottle だけを認証して読む

利用者 credential は `read:packages` だけを持つ期限付き classic PAT とします。値は承認済み secret manager から install / upgrade process へ注入し、shell history、profile、Git config、Homebrew config、Tap file、ログへ保存しません。

```sh
test -n "${GITHUB_USER:-}"
test -n "${GHCR_READ_PAT:-}"
registry_auth="$(printf '%s:%s' "$GITHUB_USER" "$GHCR_READ_PAT" | base64 | tr -d '\r\n')"
export HOMEBREW_DOCKER_REGISTRY_BASIC_AUTH_TOKEN="$registry_auth"
brew install --force-bottle zoe-llc/crewcli/crewent
unset HOMEBREW_DOCKER_REGISTRY_BASIC_AUTH_TOKEN GHCR_READ_PAT registry_auth
```

Formula は bottle がない場合の consumer source fallback を停止します。匿名 GHCR pull が成功した場合は公開事故として停止し、認証付き install を続行しません。

## 3. 更新と削除

```sh
brew update
test -n "${GITHUB_USER:-}"
test -n "${GHCR_READ_PAT:-}"
registry_auth="$(printf '%s:%s' "$GITHUB_USER" "$GHCR_READ_PAT" | base64 | tr -d '\r\n')"
export HOMEBREW_DOCKER_REGISTRY_BASIC_AUTH_TOKEN="$registry_auth"
brew upgrade zoe-llc/crewcli/crewent
unset HOMEBREW_DOCKER_REGISTRY_BASIC_AUTH_TOKEN GHCR_READ_PAT registry_auth
brew uninstall crewent
brew untap zoe-llc/crewcli
```

`formula_renames.json` は旧 `crewcli` Formula を `crewent` へ直接 rename します。runtime の `crewent login` credential は Tap read、GHCR read、automation App のいずれとも共有しません。

## 管理者の停止条件

- Tap の公開前監査と visibility 変更が明示承認されるまで public 化しない。
- repository secret 3件を別の明示承認で削除し、secret inventory 0件をread backするまでpublic化しない。
- public 化 window では Release、tag、package、bottle、canary、promotion を同時実行しない。
- public 化後に repository ID、exact main SHA、anonymous clone、protection / Actions policy が一致しなければ Release へ進まない。
- package の private visibility、private automation repository との link、permission 非継承、anonymous rejection、approved reader success が一つでも未証明なら promotion へ進まない。
- public Tap を private へ戻しても、公開済み history、Actions log、fork、cache を回収したとは扱わない。
