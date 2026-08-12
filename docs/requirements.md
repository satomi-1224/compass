# compass 要件定義

macOS ネイティブのアプリランチャー。現行の Hammerspoon 設定を完全に置き換える。

## 1. 目的とスコープ

Hammerspoon で運用している 4 機能を compass に移し、**Hammerspoon を廃止する**。Phase 1 で全機能を移植する（段階リリースはしない）。

| 現行 Hammerspoon | 現行キー | compass での扱い |
|---|---|---|
| アプリ検索ランチャー | `Cmd+Space` | 移植（`⌘⌥⇧+Space` に変更） |
| 直接ホットキー実行 | `⌘⌥⇧+{t,f,b,k,space,return}` | 移植 |
| クリップボード履歴 | `Cmd+Shift+V` | 移植（`⌘⌥⇧+V` に変更） |
| スニペット貼り付け | `⌘⌥⇧+W` | 移植 |
| ウィンドウを閉じる | `⌘⌥⇧+Delete` | **移植しない**（Accessibility API 依存のため廃止） |

ウィンドウ管理は AeroSpace、アプリ/ウィンドウ巡回は comet が担当しており、compass は関与しない。

### 新規に追加する機能

- ファイル / フォルダ検索
- Web 検索キーワード（`g swift` で Google 検索など）

インライン計算機は対象外。

## 2. アーキテクチャ

**単一プロセス・単一アプリ**。ただし内部モジュールは分離し、`HotkeyEngine` が UI に一切依存しない構造にする。将来プロセス分割したくなった際の退路を残すため。

```
compass.app (1 process)
├─ CompassCore     設定ロード / Action 実行
├─ HotkeyEngine    ← UI に依存しない
│    └ ⌘⌥⇧T → Action.run("open -a WezTerm")
├─ SearchUI        NSPanel + SwiftUI
│    └ ⌘⌥⇧Space → 検索窓 → Action.run(...)
├─ ClipboardHistory  独立モジュール（config で完全に無効化可能）
└─ Snippets
```

`ClipboardHistory` を独立させるのは、全コピー内容をディスクに永続化するという責務の性質がランチャーと異なるため。将来の除外設定追加や、丸ごと切り離す判断に備える。

## 3. 機能要件

### 3.1 トリガーキー体系

**アプリ全体で 1 種類のトリガーを定義し、その配下に全てのキーを並べる。** トリガーは `hotkeys.toml` の `trigger` に一箇所だけ書き、各アクションは単キーのみを指定する。トリガーを変えたくなったら 1 行直すだけで全体に効く。

デフォルトは `cmd+alt+shift`。現行 `command_launcher.mods` と同じ組み合わせで、指の記憶を引き継げる。`Cmd+Space` は解放され、Spotlight を戻すことも可能になる。

**例外は設けない。** トリガーを無視した個別指定（`Cmd+Shift+V` など）や、名前付きの複数トリガーは許さない。全てのキーが同一トリガー配下に並ぶため、衝突検出が単純になり、他アプリとのキーの奪い合いもトリガー 1 種だけを考えればよくなる。必要になったら後から足す。

| キー | 動作 | 種別 |
|---|---|---|
| `<trigger>+Space` | 検索窓（アプリ） | 組み込み・デフォルト固定 |
| `<trigger>+V` | クリップボード履歴 | 組み込み |
| `<trigger>+W` | スニペット一覧 | 組み込み |
| `<trigger>+{任意}` | 外部コマンド実行 | 設定で自由に定義 |

`+Space` のアプリ検索のみデフォルトとして固定し、それ以外は `hotkeys.toml` で自由に割り当てる。

### 3.2 検索窓

**キーワード切替方式（Alfred 方式）。** 素の入力はアプリ検索、先頭キーワードでモードが変わり、それ以降はそのモードのクエリとして扱う。

```
chr        → アプリ:   Google Chrome / Chromium
g swift    → Web:      Google で "swift" を検索
f report   → ファイル: ~/Documents/report.md
```

- **マッチング**: fuzzy のみ。使用頻度による並び順の学習は**行わない**。同じ入力には常に同じ結果を返す予測可能性を優先する。
- **候補操作**: `Enter` のみ。修飾キーによる副アクションは持たない。
  - アプリ → 起動 / ファイル → デフォルトアプリで開く / Web → ブラウザ起動 / クリップボード・スニペット → ペースト
- **表示位置**: 常にメインディスプレイ。マウス位置やフォーカスに追従しない。

#### アプリ・ファイルの列挙

**両方とも Spotlight index (`NSMetadataQuery`) を使う。** 実装を共有でき、インストール場所を問わずアプリを拾える。

現行 `search.lua` の `appDirs` は `~/Applications` の直下しか走査しないため、`~/Applications/Chrome Apps.localized/` 配下の PWA（Claude.app, Remap.app）が検索に出ていない。これらがホットキー直実行にしか登録されていないのはそのためで、Spotlight 化により解消される。

### 3.3 ホットキー直接実行

`hotkeys.toml` に定義したキーに外部コマンドを紐づけ、検索窓を経由せず一発で実行する。実行モデルは**外部コマンド実行のみ**。組み込みアクションは検索窓・クリップボード履歴・スニペット一覧を開く 3 つに限定する（外部コマンドでは表現できないため）。

### 3.4 クリップボード履歴

現行相当を維持する。強化はしない。

- テキストのみ（画像・ファイルは対象外）
- 最大 50 件、重複は排除して先頭に移動
- ポーリング間隔 0.8 秒
- 永続化する（現行の `hs.settings` 相当）
- 選択すると `Cmd+V` を送出してペースト

### 3.5 スニペット

- 静的テキスト
- 組み込みプレースホルダ（`{date:...}` など）— プロセス起動なしで即時展開
- 外部コマンドの出力（`body_command`）

現行の `now`（`os.date("%Y-%m-%d")`）はプレースホルダで表現する。

## 4. 設定ファイル

`~/.config/compass/` に**役割別の 3 ファイル**を置く。共通 / マシン固有の 2 層構成は**採らない** — Nix がマシンごとにファイルを生成するため、マージは Nix の責任とし、アプリ側は 3 ファイルを読むだけに保つ。

```
~/.config/compass/
├─ config.toml     アプリ本体の設定
├─ hotkeys.toml    ショートカット登録
└─ snippets.toml   スニペット登録
```

### config.toml

```toml
[appearance]
display     = "main"
width       = 680
max_results = 9

[search]
matching = "fuzzy"

[search.files]
scopes      = ["~"]
max_results = 20

[clipboard]
enabled       = true
max_items     = 50
poll_interval = 0.8

[[search.keywords]]
prefix = "f"
kind   = "file"

[[search.keywords]]
prefix = "g"
kind   = "web"
url    = "https://www.google.com/search?q={query}"
```

### hotkeys.toml

トリガーを `trigger` に 1 箇所だけ定義し、`[actions]`（組み込み）と `[commands]`（外部コマンド）にキーを並べる。現行 `command_launcher.lua` の `M.mods` + `M.commands` と 1:1 で対応する。

```toml
trigger = "cmd+alt+shift"

# 組み込みアクション
[actions]
space = "search"
v     = "clipboard"
w     = "snippets"

# 外部コマンド
[commands]
t      = "open -a WezTerm"
f      = "open -a Finder"
b      = "open -a 'Google Chrome'"
k      = "open ~/Applications/Remap.app"
return = "pgrep -f MagicBoard && pkill -f MagicBoard || ~/Work/dotfiles/magicboard/MagicBoard &"
```

- 値が単純な文字列で済み、組み込みと外部コマンドがセクションで視覚的に分かれる
- 同じキーが `[actions]` と `[commands]` の両方に現れた場合は**設定エラーとして通知**する
- キー名は `t` のような単字のほか、`space` / `return` / `delete` などの名前付きキーを受け付ける

### snippets.toml

```toml
[[snippets]]
title = "now"
body  = "{date:yyyy-MM-dd}"

[[snippets]]
title = "TwitterID"
body  = "@satomi1224_poke"

[[snippets]]
title = "branch"
body_command = "git branch --show-current"
```

## 5. 非機能要件

### 5.1 ビルドと配布

**本体は Nix store に置かない。** `scripts/install-app.sh` が `~/Applications/compass.app` へ
コピー配置し、flake が受け持つのは**設定・自動起動・ログの置き場所**に限る。

理由が二重にある。

1. **nixpkgs の Swift は 5.10。** Swift 6 を要求するコードは store の中で組めない
2. **store のパスは更新のたびに変わる。** アクセシビリティ権限はアプリの同一性に紐づくため、
   store から起動すると権限が毎回外れる

署名は**自己署名の固定証明書**で行う（`scripts/make-signing-cert.sh`）。Apple Developer
アカウントは要らない。根拠は 7.1。

同じ構成を [comet](https://github.com/satomi-1224/comet) が採っており、実運用で成立している。

### 5.2 設定のリロード

**ファイル監視による自動リロード。** `darwin-rebuild switch` で `~/.config/compass/` のシンボリックリンク先が張り替わったことを検知し、自動で再読み込みする。activation script への仕込みは不要。

### 5.3 常駐の振る舞い

- **ログイン時に自動起動**（launchd エージェント）。落ちても自動復帰する。
- **メニューバーアイコンを出さない。** Dock にも出さない、完全に不可視の常駐プロセス。
- **起動・リロード成功の通知は出さない。** 正常時は完全に黙る。

### 5.4 エラー処理

不可視常駐のため、設定の不備に気づく手段が通知しかない。

- TOML のパース失敗、不明なキー名、ホットキー登録失敗のときのみ通知センターに出す
- **エラー時は直前の正常な設定で動き続ける。** 設定を壊してもランチャーが死なない

## 6. 技術選択の根拠

| 論点 | 選択 | 理由 |
|---|---|---|
| プロセス構成 | 単一アプリ | 設定ロード・ホットキー登録・アクション実行を共有できる。分割すると `⌘⌥⇧+T` をどちらが処理するかの調停が必要になる |
| クリップボード履歴の配置 | compass に統合 | 「候補を絞り込む → 選ぶ → 実行」というアプリ検索と同一の UI パターンで、`SearchUI` を流用できる |
| ファイル検索 | Spotlight index | 自前インデックス不要。アプリ列挙と実装を共有できる |
| 設定の 2 層構成 | 採らない | Nix がマシンごとに生成するため、アプリ側でマージする必要がない |
| トリガー | 1 種のみ・例外なし | 全キーが同一トリガー配下に並ぶため衝突検出が単純になり、他アプリとのキーの奪い合いも 1 種だけ考えればよい |
| 頻度学習 | 行わない | 同じ入力に同じ結果が返る予測可能性を優先 |
| ビルドと配布 | nix store に置かない | nixpkgs の Swift は 5.10 で Swift 6 が組めず、store のパス変動で権限が外れる（7.1） |
| TOML パーサ | [dduan/TOMLDecoder](https://github.com/dduan/TOMLDecoder) | Swift 標準に TOML は無い。Codable 対応の純 Swift 実装で、同一環境の comet が実運用している |

## 7. リスクと未確定事項

### 7.1 Accessibility 権限と配布方式（検証済み・結論）

クリップボード履歴とスニペットのペーストには `CGEvent` でキーストロークを送る必要があり、**アクセシビリティ権限が必須**。macOS の TCC は **designated requirement** でアプリの同一性を判断するため、署名方式によって権限が保持されるかが変わる。

**実測した designated requirement:**

| 署名方式 | designated requirement |
|---|---|
| ad-hoc（`codesign -s -`） | `cdhash H"08e26d98…"` |
| 自己署名の固定証明書 | `identifier "local.compass-phase0" and certificate leaf = H"270b26e5…"` |

ad-hoc は **cdhash だけ**で identifier すら含まないため、リビルドで内容が 1 バイト変われば別アプリになり権限が外れる。固定証明書なら identifier と証明書の組で決まり、どちらもリビルドで変わらない。

**結論（Phase 0 で実機確認済み。2026-08-13）:**

- **自己署名の固定証明書で署名し、`~/Applications/compass.app` へコピー配置する。** リビルド → 再配置 → 再起動を経ても、権限を再付与せずキーストローク送出が成功する
- **Apple Developer アカウントは不要。** `TeamIdentifier=not set` の自己署名で保持される
- **nix store へ置く方式は採らない**（理由は 5.1）

cdhash と inode が入れ替わっても `AXIsProcessTrusted()` が true のままであることを 3 回のリビルドで確認した。検証の詳細と再現手順は [experiments/phase0-permission/README.md](../experiments/phase0-permission/README.md)。

### 7.2 デフォルト値の確定が必要な項目

- Web 検索キーワードのデフォルトセット（`g` = Google、`gh` = GitHub を想定）
- ファイル検索の Spotlight 探索範囲（ホームディレクトリのみを想定）
- 検索窓の外観の細部（角丸、ブラー、行の高さ、アイコンサイズ）
- アプリ名の日本語・かなマッチングの扱い

### 7.3 現行設定からの移植対象

`command_launcher_local.lua` の `⌘⌥⇧+Return`（MagicBoard のトグル）は、シェルで表現できるため `[commands]` の 1 行として移植できる。

```toml
[commands]
return = "pgrep -f MagicBoard && pkill -f MagicBoard || ~/ghq/github.com/satomi-1224/dotfiles-global/magicboard/MagicBoard &"
```

`⌘⌥⇧+K` の Remap は `~/Applications/Chrome Apps.localized/Remap.app` を開いている（4 章の設定例は `~/Applications/Remap.app` と略記しているが、実体はこちら）。

> **現行設定が壊れている**: `command_launcher_local.lua` は `~/Work/dotfiles/magicboard/MagicBoard` を参照しているが、このパスは存在しない。実体は `~/ghq/github.com/satomi-1224/dotfiles-global/magicboard/MagicBoard` へ移っており、**現在 `⌘⌥⇧+Return` は何も起動しない**。移植時は新しいパスを使う。

`~` や `$HOME` を展開するかは外部コマンドの実行方法（`sh -c` を通すか）に依存する。Phase 2 で確定する。

### 7.4 実装上の制約（Phase 0 で判明）

**`Cmd+V` を解釈させるには `NSApp.mainMenu` に Edit メニューが必要。** AppKit はキー等価物をメインメニューで解決するため、メニューが無いと `Cmd+V` の keyDown はビューまで届くのに `paste:` へ変換されず何も起きない。Phase 0 の検証で、送出は成功しているのにペーストされない状態を実測した。

`LSUIElement = true` でメニューバーを表示しなくても `NSApp.mainMenu` の設定自体は必要になる。検索窓・クリップボード履歴・スニペット一覧の入力欄で編集操作（ペースト・全選択）を効かせるため、Phase 1 で最小のメインメニューを組む。
