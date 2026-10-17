# Public Tap / private GHCR access

## 現在の状態

2026-10-17 時点では Tap `zoe-llc/homebrew-crewent` は public Formula-only surface として準備済みで、Release、GHCR package、実 canary、stable promotion は未実行です。この文書の install 手順は Internal Activation 後にだけ利用します。

Tap が匿名公開するのは Formula と公開可能な digest / evidence だけです。compatibility Formula や rename metadata は保持しません。source repository、Release asset、bottle payload は公開しません。Tap の公開は OSS 化や公開ライセンス付与を意味しません。

## 所有権

public Tap は Formula-only read 面です。public化後は repository secret、package permission、protected Actions artifact、private App key、GHCR credential、mutation workflow を持ちません。唯一の workflow は secret-free な `validate.yml` です。

repository secret は 0 件で、source Reader credential、private App key、GHCR credential を保持しません。

private [`zoe-llc/crewent-distribution`](https://github.com/zoe-llc/crewent-distribution) が source manifest import、bottle build / publish、GHCR read-back、candidate draft PR、3 target canary、final promotion evidence を所有します。public Tap の `GITHUB_TOKEN` を private package や source repository へ接続しません。

## 1. public Tap を匿名取得する

Activation 後は GitHub credential を渡さず、通常の一引数形式で取得します。

```sh
brew tap zoe-llc/crewent
brew trust --formula zoe-llc/crewent/crewent
```

匿名 Tap が失敗した場合は private clone、credential 付き clone、source build へ fallback しません。repository ID `1414534332`、public visibility、default branch `main`、GitHub availability を確認して停止します。

## 2. private GHCR bottle だけを認証して読む

利用者 credential は `read:packages` だけを持つ期限付き classic PAT とします。値は承認済み secret manager から install / upgrade process へ注入し、shell history、profile、Git config、Homebrew config、Tap file、ログへ保存しません。

```sh
test -n "${GITHUB_USER:-}"
test -n "${GHCR_READ_PAT:-}"
registry_auth="$(printf '%s:%s' "$GITHUB_USER" "$GHCR_READ_PAT" | base64 | tr -d '\r\n')"
export HOMEBREW_DOCKER_REGISTRY_BASIC_AUTH_TOKEN="$registry_auth"
brew install --force-bottle zoe-llc/crewent/crewent
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
brew upgrade zoe-llc/crewent/crewent
unset HOMEBREW_DOCKER_REGISTRY_BASIC_AUTH_TOKEN GHCR_READ_PAT registry_auth
brew uninstall crewent
brew untap zoe-llc/crewent
```

runtime の `crewent login` credential は Tap read、GHCR read、automation App のいずれとも共有しません。

## 管理者の停止条件

- repository ID、exact main SHA、anonymous clone、protection / Actions policy が一致しなければ Release へ進まない。
- package の private visibility、private automation repository との link、permission 非継承、anonymous rejection、approved reader success が一つでも未証明なら promotion へ進まない。
- public Tap を private へ戻しても、公開済み history、Actions log、fork、cache を回収したとは扱わない。
