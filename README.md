<p align="center">
  <img src="docs/icon.png" width="128" alt="compass">
</p>

<h1 align="center">compass</h1>

<p align="center">
  <b>macOS 向けのアプリランチャー</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey" alt="platform">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="swift">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="license">
</p>

アプリ・ファイル・Web とプラグインコマンドを 1 つの検索窓から開き、よく使うコマンドは
窓を経由せず一発で実行します。クリップボード履歴とスニペットも同じ窓から選べます。
**メニューバーにも Dock にも出ない常駐プロセス**です。

```
┌────────────────────────────────────────────┐
│ 🔍  chr                                    │
├────────────────────────────────────────────┤
│ 🌐  Google Chrome      /Applications        │
│ 🌐  Chromium           /Applications        │
└────────────────────────────────────────────┘
   ⌘⌥⇧Space で検索、⌘⌥⇧V で履歴、⌘⌥⇧W でスニペット
```

## 特長

- **入口は 2 つだけ** — 検索窓（`⌘⌥⇧Space`）と、窓を経由しない直接ホットキー
- **キーワードで切り替わる** — `g swift` で Google、`f report` でファイル検索
- **プラグインも通常検索から開ける** — `sni` や `スニペット` でコマンドを探し、
  選ぶとその一覧へ移る
- **並び順が変わらない** — fuzzy マッチのみで**使用頻度は学習しない。** 同じ入力には
  常に同じ結果が返る
- **見えている名前で引ける** — Finder と同じ表示名（「システム設定」「計算機」）で
  探せて、英名（`System Settings`）でも同じ候補に当たる
- **クリップボード履歴** — テキスト 50 件。パスワードマネージャが「保存するな」と
  印を付けた内容は残さない
- **スニペット** — 静的テキスト、`{date:yyyy-MM-dd}` などのプレースホルダ、
  外部コマンドの出力
- **設定は責務ごとに分離** — プラグイン設定は `plugins/` 配下。保存すると自動で読み直し、
  **不備があっても直前の正常な設定で動き続ける**
- **トリガーは 1 種類だけ** — `hotkeys.toml` の 1 行を直せば全キーに効く

## 動作要件

- macOS 14 以降
- Swift 6 ツールチェイン（Xcode は不要。Command Line Tools だけで組める）
- アクセシビリティ権限（クリップボード履歴とスニペットのペーストに必要）

## インストール

```bash
git clone https://github.com/satomi-1224/compass.git
cd compass

# 1. 署名 ID を作る（一度だけ。省略すると入れ替えのたびに権限を求められる）
./scripts/make-signing-cert.sh

# 2. .app を組み立てて ~/Applications へ入れる
./scripts/install-app.sh release
```

初回起動時に**アクセシビリティ権限**を求められます。「システム設定 > プライバシーと
セキュリティ > アクセシビリティ」で許可してください。

> [!IMPORTANT]
> **アクセシビリティ権限はコード署名の同一性に紐づきます。** ad-hoc 署名のままだと
> 内容が変わるたびにハッシュが変わり、入れ替えるたびに許可を求められます。
> `make-signing-cert.sh` で固定の署名 ID を作っておくと出なくなります。Apple Developer
> アカウントは要りません（[検証の記録](experiments/phase0-permission/README.md)）。

### Nix（home-manager）で使う

設定と自動起動を宣言的に持てます。flake を input に足して、home-manager の
モジュールを読み込みます。

```nix
{
  inputs.compass.url = "github:satomi-1224/compass";

  # home-manager の設定
  imports = [ inputs.compass.homeManagerModules.default ];

  programs.compass = {
    enable = true;

    hotkeys = {
      trigger = "cmd+alt+shift";
      actions = { space = "search"; v = "clipboard"; w = "snippets"; };
      commands = {
        t = "open -a WezTerm";
        f = "open -a Finder";
        b = "open -a 'Google Chrome'";
      };
    };

    plugins.snippets.entries = [
      { title = "now"; body = "{date}"; }
      { title = "branch"; body_command = "git branch --show-current"; }
    ];
  };
}
```

| オプション | 既定 | 内容 |
|---|---|---|
| `enable` | `false` | 有効にする |
| `settings` | `{}` | `config.toml` の内容 |
| `hotkeys` | `{}` | `hotkeys.toml` の内容 |
| `plugins.snippets.entries` | `[]` | `plugins/snippets.toml` の `[[snippets]]` |
| `settingsFile` / `hotkeysFile` / `plugins.snippets.settingsFile` | `null` | 書いてある TOML をそのまま置く。属性集合より優先 |
| `app` | `~/Applications/compass.app` | 本体の場所 |
| `startService` | `true` | launchd agent として登録し、ログイン時に起動する |
| `logFile` | `~/Library/Logs/compass.log` | launchd から起動したときのログ |
| `logLevel` | `"info"` | `debug` / `info` / `warn` / `error` / `off` |

> [!IMPORTANT]
> **本体は Nix ストアに置きません。** 理由は 2 つあります。
> 1. compass は Swift 6 を要求しますが、nixpkgs の Swift は 5.10 でストアの中では組めません
> 2. アクセシビリティ権限はアプリの同一性に紐づくため、更新のたびにパスが変わる
>    ストアへ置くと権限が毎回外れます
>
> 本体は `./scripts/install-app.sh` が `~/Applications/compass.app` へ入れます。
> モジュールが受け持つのは**設定・自動起動・ログの置き場所**です。

## 使い方

トリガーは `hotkeys.toml` に 1 箇所だけ書き、各キーは単キーで指定します。
既定は `⌘⌥⇧`。

| キー | 動作 |
|---|---|
| `<trigger>+Space` | 検索窓 |
| `<trigger>+V` | クリップボード履歴 |
| `<trigger>+W` | スニペット一覧 |
| `<trigger>+{任意}` | 外部コマンドを一発で実行 |

別の入口のキーを押すと**そちらへ切り替わります**（履歴を見ている最中に `⌘⌥⇧W` を
押すとスニペットが出ます）。同じキーをもう一度押すと閉じます。

窓の中のキー操作は次の通りです。他のアプリへ移っても閉じます。
**修飾キーによる副アクションはありません**（`Enter` だけ）。

| キー | 動作 |
|---|---|
| `↑` `↓` / `^P` `^N` | 1 つ動かす |
| `PageUp` `PageDown` | 1 画面ぶん動かす |
| `Home` `End` / `⌘↑` `⌘↓` | 先頭・末尾へ飛ぶ |
| `Enter` | 実行 |
| `Esc` | 閉じる |

### 検索窓

素の入力はアプリとプラグインコマンドの検索、先頭のキーワードでモードが変わります。

```
chr        → アプリ:   Google Chrome / Chromium
設定       → アプリ:   システム設定
sni        → コマンド: スニペット
g swift    → Web:      Google で "swift" を検索
f report   → ファイル: ~/Documents/report.md
```

キーワードだけを打った時点では切り替わりません（空白が続いて初めて切り替わる）。
`g` で始まるアプリを探せるようにするためです。

**アプリ名は Finder と同じ表示名で並びます。** 「システム設定」「計算機」「メモ」の
ように日本語で出るものは日本語で引け、英名（`System Settings`）でも同じ候補に当たります。
かなとカタカナ、全角と半角の英数は区別しません（`ｃａｌ` でも当たります）。
入力に当たった文字は候補の中で太く出ます。

候補が無いときは窓が縮まず、理由を 1 行だけ出します（「一致するものがない」
「探しています…」）。

> [!NOTE]
> **ファイル検索は Spotlight のインデックスを使います。** `mdutil -s /` が
> `Indexing disabled.` を返す環境では常に 0 件になるので、`sudo mdutil -i on /` で
> 有効にするか、`config.toml` からファイル検索のキーワードを外してください。
> アプリの列挙は自前で走査するので、インデックスが無くても動きます。

## 設定

`~/.config/compass/` に役割別のファイルを置きます。**保存すると自動で読み直します**
（`darwin-rebuild switch` によるシンボリックリンクの張り替えも検知します）。

```
config.toml     アプリ本体の設定
hotkeys.toml    ショートカット登録
plugins/
└─ snippets.toml   スニペットプラグインの設定
```

既存の Nix 設定にある `snippets` / `snippetsFile` は移行用の別名として引き続き読めます。
新しい名前へ変更すると警告も消えます。TOML を直接置いている場合だけ、従来の
`snippets.toml` を `plugins/snippets.toml` へ移してください。

**設定の誤りで常駐は止まりません。** 不備があると通知センターに出て、**直前の正常な
設定のまま動き続けます**。範囲外の値は丸めずにエラーにします（丸めると「設定したのに
効いていない」状態に気づけないため）。

不備があるあいだは**検索窓を開いた時点でも出ます**（`Enter` でそのファイルが開きます）。
通知は環境によって届かないことがあるので、そこだけに頼りません。

### config.toml

```toml
[appearance]
width       = 680
max_results = 9

[clipboard]
enabled       = true
max_items     = 50
poll_interval = 0.8

[search.files]
scopes      = ["~"]
exclude     = ["~/Library"]
max_results = 20

[[search.keywords]]
prefix = "g"
kind   = "web"
url    = "https://www.google.com/search?q={query}"
```

`search.keywords` は**置き換え**です（既定へ追加されるのではありません）。書かなければ
`f` = ファイル、`g` = Google、`gh` = GitHub が使われます。

`search.files.exclude` に書いた場所の下はファイル検索の結果から外します。既定の
`~/Library` にはアプリの支援ファイルが数万件あり、自分で置いたファイルを押しのけて
しまうためです。`exclude = []` と書けば全部出ます。

### hotkeys.toml

```toml
trigger = "cmd+alt+shift"

[actions]
space = "search"
v     = "clipboard"
w     = "snippets"

[commands]
t = "open -a WezTerm"
f = "open -a Finder"
```

`[actions]` には本体の `search` / `clipboard` と、登録済みプラグインのコマンド ID
（現在は `snippets`）を書けます。それ以外は `[commands]` に外部コマンドとして書きます
（`/bin/sh -c` を通すので `~` や `&&` が使えます）。

**同じキーが両方にあると設定エラーになります。** `return` と `enter` のように綴りが
違っても同じ物理キーなら衝突として扱います。書けるキー名は `compass --print-keys` で
出ます。

### plugins/snippets.toml

```toml
[[snippets]]
title = "now"
body  = "{date:yyyy-MM-dd}"

[[snippets]]
title = "branch"
body_command = "git branch --show-current"
```

`body`（静的テキスト）か `body_command`（外部コマンドの出力）の**どちらか一方**を書きます。
`body_command` は**一覧を開いた時点では実行しません**（選んでいないコマンドが走らない
ように）。

書けるプレースホルダは `compass --print-placeholders` で出ます。

| 記法 | 展開 |
|---|---|
| `{date}` | `yyyy-MM-dd` |
| `{date:<書式>}` | 指定した書式（例 `{date:yyyy年M月d日}`） |
| `{time}` / `{time:<書式>}` | `HH:mm` |
| `{datetime}` | `yyyy-MM-dd HH:mm:ss` |
| `{uuid}` | 小文字の UUID |

知らないプレースホルダはそのまま残るので、`{foo}` はリテラルとして書けます。

## 動作を確かめる

メニューバーにも Dock にも出ないので、動いているかは次で確かめます。

```bash
launchctl print gui/$(id -u)/org.nix-community.home.compass
tail -f ~/Library/Logs/compass.log
```

ホットキーを押さずに窓を出したり、検索結果を確かめたりできます。

```
--show-search [クエリ]       検索窓を出す
--show-clipboard             クリップボード履歴を出す
--show-snippets              スニペット一覧を出す
--print-candidates <クエリ>  検索結果を出して終わる
--print-apps                 列挙したアプリを出して終わる
--print-keys                 hotkeys.toml に書けるキー名
--print-placeholders         plugins/snippets.toml に書けるプレースホルダ
```

```bash
$ compass --print-candidates "g swift"
swift	https://www.google.com/search?q=swift
```

`COMPASS_LOG_LEVEL=debug` でログの粒度を上げられます。

## 開発

```bash
swift build          # ビルド
./scripts/test.sh    # テスト
./scripts/build-app.sh debug   # .app を組み立てる（署名まで）
./scripts/make-icon.sh <元画像> # アイコンを作り直す
```

Xcode は要りません。`scripts/env.sh` が `Testing.framework` の探索パスを補います
（Command Line Tools だけの環境では SPM が自力で見つけられないため）。

### 構成

```
CompassCore       設定ロード / Action 実行 / 候補の型 / fuzzy マッチ  ← UI を知らない
HotkeyEngine      Carbon のグローバルホットキー                       ← SearchUI に依存しない
SearchUI          NSPanel + NSTableView の検索窓
PluginKit         検索可能なコマンド / 一覧 / 設定ライフサイクルの契約
ClipboardHistory  ポーリング監視と永続化
plugins/catalog   同梱プラグインの登録口
plugins/snippets  スニペットの設定 / 展開 / 候補生成
```

`HotkeyEngine` が `SearchUI` を知らないことをモジュール境界で担保しています。
プラグイン追加の手順と境界は [plugins/README.md](plugins/README.md)、設計判断は
[docs/plugin-architecture.md](docs/plugin-architecture.md) にまとめています。

設計の根拠と、実装中に判明して方針を変えた点は
[docs/requirements.md](docs/requirements.md) にあります。

## ライセンス

MIT
