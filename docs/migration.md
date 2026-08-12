# Hammerspoon から compass への移行

現行の Hammerspoon 設定（`~/.hammerspoon/`）を読んで突き合わせた結果と、そのまま使える
home-manager の設定を置く。タスクは [tasks.md](./tasks.md) の Phase 6 を参照。

## 突き合わせ

| 現行キー | 現行の動作 | 定義場所 | compass | 備考 |
|---|---|---|---|---|
| `Cmd+Space` | アプリ検索 | `search.lua` | `⌘⌥⇧+Space` | `Cmd+Space` が空く |
| `⌘⌥⇧+Space` | Claude.app を開く | `command_launcher.lua` | **移植しない** | **現在も動いていない**（下記） |
| `⌘⌥⇧+T` | WezTerm | `command_launcher.lua` | `[commands] t` | |
| `⌘⌥⇧+F` | Finder | `command_launcher.lua` | `[commands] f` | |
| `⌘⌥⇧+B` | Google Chrome | `command_launcher.lua` | `[commands] b` | |
| `⌘⌥⇧+K` | Remap.app | `command_launcher_local.lua` | `[commands] k` | |
| `⌘⌥⇧+Return` | MagicBoard トグル | `command_launcher_local.lua` | `[commands] return` | **パスが古い**（下記） |
| `⌘⌥⇧+Delete` | ウィンドウを閉じる | `command_launcher.lua` | **移植しない** | Accessibility API 依存（requirements.md 1章） |
| `Cmd+Shift+V` | クリップボード履歴 | `clipboard.lua` | `⌘⌥⇧+V` | トリガーに揃える |
| `⌘⌥⇧+W` | スニペット | `snippets_init.lua` | `⌘⌥⇧+W` | そのまま |

## 現行設定の壊れている箇所

**そのまま持ち込むと動かないものが 2 つある。** どちらも現時点で既に動いていない。

### 1. `⌘⌥⇧+Space` の Claude.app が無い

`command_launcher.lua` は `~/Applications/Chrome Apps.localized/Claude.app` を開くが、
このパスは存在しない（同ディレクトリには `Remap.app` だけ）。**現在このキーは何も
起動しない。**

requirements.md では「Claude を別のキーへ移す必要がある」としていたが、**移す対象が
無いので検索窓へ明け渡すだけで済む。** Claude を使うなら compass の検索窓から
`Claude Code URL Handler` を選ぶか、別途インストールして `[commands]` に足す。

### 2. `⌘⌥⇧+Return` の MagicBoard のパスが古い

`~/Work/dotfiles/magicboard/MagicBoard` を指しているが、実体は
`~/ghq/github.com/satomi-1224/dotfiles-global/magicboard/MagicBoard` へ移っている。
**現在このキーも何も起動しない。** 移植時は新しいパスを使う。

## スニペット

| 現行 | 現行の body | compass |
|---|---|---|
| `now` | `os.date("%Y-%m-%d")` | `body = "{date}"` |
| `TwitterID` | `@satomi1224_poke` | そのまま |
| `mail` | `yazawaryo@outlook.jp` | そのまま |

`{date}` は `yyyy-MM-dd`。書ける記法は `compass --print-placeholders` で出る。

## クリップボード履歴

現行の設定値は compass の既定と一致している（最大 50 件、ポーリング 0.8 秒）。

**履歴の中身は引き継がない。** 現行は `hs.settings`（`org.hammerspoon.Hammerspoon.plist`
の `clipboard_history` キー）に持っているが、数日で入れ替わる性質のもので移す価値が薄い。
どうしても要るなら移行前に取り出しておく:

```bash
defaults read org.hammerspoon.Hammerspoon clipboard_history
```

compass は `~/Library/Application Support/compass/clipboard.json` に JSON の文字列配列で
持つ（パーミッション `0600`）。手で書けば読み込まれる。

## home-manager の設定

`dotfiles/flake.nix` の `inputs` に足す:

```nix
compass.url = "github:satomi-1224/compass";
```

home-manager の設定に:

```nix
{ inputs, ... }:
{
  imports = [ inputs.compass.homeManagerModules.default ];

  programs.compass = {
    enable = true;

    settings = {
      appearance = {
        width = 680;
        max_results = 9;
      };
      clipboard = {
        enabled = true;
        max_items = 50;
        poll_interval = 0.8;
      };
      # **ファイル検索は Spotlight のインデックスが要る。** このマシンでは無効
      # （requirements.md 7.5）。有効にしないなら prefix = "f" を書かない。
      search.keywords = [
        { prefix = "g"; kind = "web"; url = "https://www.google.com/search?q={query}"; }
        { prefix = "gh"; kind = "web"; url = "https://github.com/search?q={query}"; }
      ];
    };

    hotkeys = {
      trigger = "cmd+alt+shift";

      actions = {
        space = "search";
        v = "clipboard";
        w = "snippets";
      };

      commands = {
        t = "open -a WezTerm";
        f = "open -a Finder";
        b = "open -a 'Google Chrome'";
        k = ''open "$HOME/Applications/Chrome Apps.localized/Remap.app"'';
        return = ''
          pgrep -f MagicBoard && pkill -f MagicBoard \
            || "$HOME/ghq/github.com/satomi-1224/dotfiles-global/magicboard/MagicBoard" &
        '';
      };
    };

    snippets = [
      { title = "now"; body = "{date}"; }
      { title = "TwitterID"; body = "@satomi1224_poke"; }
      { title = "mail"; body = "yazawaryo@outlook.jp"; }
    ];
  };
}
```

## 手順

```bash
cd ~/ghq/github.com/satomi-1224/compass

# 1. 署名 ID を作る（一度だけ。既に compass-dev があれば飛ばす）
./scripts/make-signing-cert.sh

# 2. ~/Applications/compass.app へ入れる
./scripts/install-app.sh release

# 3. アクセシビリティ権限を付与する
#    システム設定 > プライバシーとセキュリティ > アクセシビリティ で compass を許可
#    （クリップボード履歴とスニペットのペーストに必要。requirements.md 7.1）
```

4. 上の設定を home-manager に足して `darwin-rebuild switch`
5. **Hammerspoon 側のキーバインドを外す。** 外さないと同じキーを両方が掴む
   （Carbon のホットキー登録はプロセス間で排他にならない。実測で compass 側は
   Hammerspoon が動いている状態でも 4/4 件の登録に成功した）
6. 数日 compass だけで運用する
7. 問題がなければ dotfiles から Hammerspoon 設定を削除する

## `Cmd+Space` の扱い

現行は Hammerspoon のアプリ検索が握っている。compass は `⌘⌥⇧+Space` を使うので空く。

| 選択肢 | やること |
|---|---|
| Spotlight を戻す | システム設定 > キーボード > キーボードショートカット > Spotlight で有効化 |
| 空けたままにする | 何もしない。誤爆が減る |

決めるのは移行のとき。compass 側の設定は変わらない。
