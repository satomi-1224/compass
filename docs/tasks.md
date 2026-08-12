# compass 実装タスク

要件は [requirements.md](./requirements.md) を参照。

## 運用ルール

- 着手前 `- [ ]` / 完了 `- [x]`。完了にするのは**実機で動作確認できたとき**のみ
- フェーズは上から順に進める。Phase 0 の結論次第で Phase 1 以降の前提が変わる
- 決定が変わったら requirements.md を先に直し、その差分をタスクに反映する
- 保留・却下した項目は消さず、理由を添えて残す

---

## Phase 0: 権限検証（完了）

**目的**: `.app` でアクセシビリティ権限が安定して保持されるかを確かめる。ここが破綻するとクリップボード履歴とスニペットが実用にならず、配布方式かビルド方式の再検討が必要になる。

**完了条件**: リビルド → 再配置 → 再起動を経ても、権限を再付与せずにキーストローク送出が成功する。

**結論（2026-08-13 実機確認）**: **自己署名の固定証明書で署名し `~/Applications/` へコピー配置すれば権限は保持される。** nix store へ本体を置く方式は採らない。詳細は requirements.md 5.1 / 7.1、再現手順は [experiments/phase0-permission/README.md](../experiments/phase0-permission/README.md)。

- [x] 最小の `.app` をビルドする（`CGEvent` で `Cmd+V` を送るだけのもの）
  - `experiments/phase0-permission/`。判定は自分のテキストフィールドへ送って自己完結させた
- [x] アクセシビリティ権限を手動付与し、キーストローク送出が成功することを確認
- [x] コードを変更して**リビルドし、権限が保持されるか**を確認
  - cdhash と実行ファイルの inode が変わっても `AXIsProcessTrusted()` は true のまま（3 回のリビルドで確認）
- [x] 対策を検証する
  - [x] 案A: `~/Applications/compass.app` へ**コピー**配置しパスを固定する → **採用**（案C と併用）
  - [x] 案B: ad-hoc 署名 → **却下**。designated requirement が `cdhash H"…"` だけになり identifier すら含まないため、リビルドで別アプリ扱いになる
  - [x] 案C: 安定した署名 → **採用**。ただし **Apple Developer アカウントは不要**で、自己署名の固定証明書（`scripts/make-signing-cert.sh`）で足りる
- [x] 結論を requirements.md 7.1 に追記し、採用する配布方式を確定した

> **Nix store ビルドは検証せず却下した。** 理由が二重にあるため（requirements.md 5.1）。nixpkgs の Swift は 5.10 で Swift 6 を要求するコードが組めず、store のパスは更新ごとに変わるため権限が保持されない。同じ判断を comet が先に下している。

> **副産物**: `NSApp.mainMenu` に Edit メニューが無いと `Cmd+V` が `paste:` に解決されないことが判明した（送出は成功しているのにペーストされない）。requirements.md 7.4 に記録し、Phase 1 のタスクに落とした。

---

## Phase 1: プロジェクト基盤

**完了条件**: 不可視の常駐プロセスがログイン時に起動し、3 つの TOML を読み、壊れた設定を通知しつつ旧設定で動き続ける。

### ビルド

- [x] `CompassCore` を作る（設定ロードと Action 実行。**UI に依存しない**）
- [ ] 残りのモジュールは各フェーズで足す
  - `HotkeyEngine` → Phase 2 / `SearchUI` → Phase 3 / `ClipboardHistory` → Phase 4 / `Snippets` → Phase 5
  - `HotkeyEngine` が `SearchUI` に依存しないことをモジュール境界で担保する
- [x] `.app` バンドルの生成（`Info.plist`、`LSUIElement = true` で Dock 非表示）
  - `lsappinfo` で `type="UIElement"` を確認（前景アプリは `type="Foreground"`）
- [x] `scripts/build-app.sh` — `swift build` → バンドル組み立て → `compass-dev` で署名
  - 署名 ID が無ければ ad-hoc に落とし、**権限が外れる旨を警告する**
- [x] `scripts/install-app.sh` — `~/Applications/compass.app` へ入れ替え、launchd を読み直す
  - 動いているプロセスは先に止める。バンドルを差し替えると署名の検証に失敗して落ちる
  - **plist が無いなら `bootout` しない**（戻す手段が無く、登録を消して終わる）
  - 隣に置いてから `mv` で差し替える（コピー失敗でアプリが 1 つも残らない事態を避ける）
- [x] flake で home-manager モジュールを提供する
  - 受け持つのは**設定・自動起動・ログの置き場所のみ**。本体は store に置かない
- [x] `scripts/env.sh` — Xcode が無い環境で `Testing.framework` を解決する
  - CLT だけだと SPM が自力で見つけられない。探索パスと rpath を明示的に渡す

> **却下**: 「Nix flake で `.app` までビルドする」は Phase 0 の結論により採らない（requirements.md 5.1）。

### 設定

- [x] TOML パーサを導入する（[dduan/TOMLDecoder](https://github.com/dduan/TOMLDecoder) に決定。comet と揃える）
  - キーは `.convertFromSnakeCase` で変換する。設定は snake_case で書く
- [x] `config.toml` / `hotkeys.toml` / `snippets.toml` のスキーマを型として定義
  - `hotkeys.toml` は `trigger` 1 行 + `[actions]` + `[commands]` のセクション分割
  - `body` / `body_command` は enum で排他にした（両方書けない）
- [x] 3 ファイルのロード処理（ファイル欠損は空として扱い、エラーにしない）
- [x] バリデーション
  - [x] 不明なキー名、必須項目の欠落
  - [x] **`[actions]` と `[commands]` の間のキー衝突**（同じキーが両方にある）
    - **キーコードで見る。** `return` と `enter` は同じ物理キーなので、綴りが違っても衝突
  - [x] `[actions]` の値が組み込みアクション名（`search` / `clipboard` / `snippets`）であること
  - [x] 範囲外の値は**丸めずにエラーにする**（丸めると設定が効いていないことに気づけない）
  - [x] `trigger` に cmd / alt / ctrl のいずれかを要求する（shift だけだと通常のタイピングを奪う）
- [x] **エラー時は直前の正常な設定を保持して動き続ける**
  - 成功したファイルだけが差し替わる。壊れたファイルは直前の内容を保つ
- [x] エラーのみ通知センターに出す（正常時は完全に無音）
  - 許可要求は**最初にエラーを出すときだけ**。エラーが起きなければダイアログも出ない
- [x] ファイル監視による自動リロード
  - [x] `darwin-rebuild switch` でのシンボリックリンク張り替えを検知できることを実機確認した
  - [x] ディレクトリ自体がシンボリックリンクの場合は**親ディレクトリ**を見る
    （`open` はリンクを追うため、リンクを張り替えても古い実体を見続ける）

> **`config.toml` の未知セクション・未知キーは検出しない。** `.convertFromSnakeCase` を
> 使っている関係で、`allKeys` から得られる綴りが設定に書いた綴り（snake_case）と
> 一致せず、報告がかえって分かりにくくなる。上の「不明なキー名」は `hotkeys.toml` の
> キー名（`t` / `space` など）を指す。必要になったら生の TOML 木を別に読んで足す。

### 常駐

- [ ] launchd エージェントでログイン時に自動起動し、落ちても復帰する
  - home-manager モジュールは書いた（`KeepAlive = true`）。**実機での登録は未確認**
- [x] メニューバーにも Dock にも一切出ないことを確認
- [x] 最小のメインメニュー（Edit）を組む
  - **`NSApp.mainMenu` が無いと `Cmd+V` が `paste:` に解決されない**（Phase 0 で実測）。`LSUIElement = true` でメニューバーを出さなくても設定自体は必要（requirements.md 7.4）
  - Quit にキー等価物は付けない（検索窓を開いている最中の `Cmd+Q` で常駐が落ちると全て死ぬ）

---

## Phase 2: HotkeyEngine

**完了条件**: 現行 `command_launcher` のホットキーが compass 経由で全て動く。

- [ ] グローバルホットキー登録の方式を決める（Carbon `RegisterEventHotKey` を第一候補）
- [ ] `trigger` のパース（`"cmd+alt+shift"` → 修飾キーのビットマスク）
- [ ] 単キーのパース（`t` / `space` / `return` / `delete` → キーコード）
  - 不明なキー名は Phase 1 のバリデーションでエラーにする
  - トリガーを無視した個別指定は**受け付けない**（例外なしの方針）
- [ ] トリガー + 単キーを組み合わせて登録する
- [ ] `[commands]` の外部コマンド実行
- [ ] `[actions]` の組み込みアクションのディスパッチ（`search` / `clipboard` / `snippets` の 3 つのみ）
- [ ] ホットキー登録の衝突・失敗を検出して通知する
- [ ] 現行の全ホットキーを移植して動作確認
  - [ ] `⌘⌥⇧+T` WezTerm / `+F` Finder / `+B` Chrome
  - [ ] `⌘⌥⇧+Space` Claude（現行）→ **検索窓に置き換わるため再割り当てが必要**
  - [ ] `⌘⌥⇧+K` Remap
  - [ ] `⌘⌥⇧+Return` MagicBoard トグル（シェルで表現）

> `⌘⌥⇧+Space` は現行では Claude.app の起動に使われている。compass ではアプリ検索に固定するため、**Claude を別のキーへ移す必要がある**。移行時に決める。

---

## Phase 3: SearchUI

**完了条件**: `⌘⌥⇧+Space` でアプリを検索・起動でき、キーワードでファイル検索と Web 検索に切り替わる。

### ウィンドウ

- [x] `NSPanel` + AppKit で検索窓を作る（非アクティブ化で閉じる、Esc で閉じる）
  - **SwiftUI ではなく AppKit にした。** `Esc` / `↑↓` / `Enter` は field editor が
    先に受け取るため、`doCommandBy` で捕まえるのが確実（requirements.md 6章）
  - `.nonactivatingPanel` を使い、**前面のアプリを保ったまま**キー入力を受ける。
    Phase 4/5 のペースト先が変わらないようにするため
  - 表がフォーカスを奪うと文字が打てない。`refusesFirstResponder` で防ぐ
- [x] 常にメインディスプレイの上寄り中央に出す
  - `NSScreen.main` はキーウィンドウのある画面を返す。`screens.first` を使う
- [x] 外観を詰める（角丸・ブラー・行の高さ・アイコンサイズ）→ requirements.md 7.2 に確定値
- [ ] 実機で見た目と操作（`↑↓` 選択、`Enter` 実行、`Esc` で閉じる）を確認する

### 検索

- [x] fuzzy マッチングの実装（頻度学習は**行わない**）
  - 同点は名前順で決める。到着順に依存すると同じ入力で並びが変わる
  - 頭字語の終わり（`VSCode` の `C`、`HTTPServer` の `S`）も単語の頭として加点する
- [x] キーワード切替のパース（先頭トークンで判定、以降をクエリとして扱う）
  - **キーワードだけではモードを変えない。** `g` の時点で切り替えると `g` で始まる
    アプリを探せなくなる。空白が続いて初めて切り替える
- [x] アプリ検索
  - **`NSMetadataQuery` をやめ、自前走査にした**（requirements.md 3.2 / 7.5）。
    このマシンでは Spotlight が無効で 0 件しか返らない
  - [x] `~/Applications/Chrome Apps.localized/` 配下の PWA が拾えることを確認（現行の積み残し）
  - [x] `~/Applications/Home Manager Apps/` 配下も拾えることを確認
    - ディレクトリ自体が nix store へのシンボリックリンク。**追わないと 1 つも拾えない**
  - [x] アプリ名の日本語・かなマッチングの扱いを決める → 英名のみ（requirements.md 7.2）
- [x] ファイル検索（`NSMetadataQuery`、探索範囲は config の `scopes`）
  - 部分列を `*d*c*m*` のワイルドカードに開いて粗く集め、並べ替えは fuzzy に任せる
  - **このマシンでは Spotlight が無効なため実際には 0 件になる**（requirements.md 7.5）
- [x] Web 検索（URL テンプレートの `{query}` を置換してブラウザ起動）
  - [x] デフォルトキーワードを決める → `g` = Google、`gh` = GitHub（requirements.md 7.2）
- [x] `Enter` で実行（修飾キーによる副アクションは持たない）

### 開発用の入口

- [x] `--show-search [クエリ]` — ホットキーを押さずに検索窓を出す
  - 常用のホットキーが他のアプリと衝突している状況でも検証できる
- [x] `--print-apps` — 列挙したアプリを出して終了する
  - 自前走査が意図した範囲を拾えているかを確かめる

---

## Phase 4: ClipboardHistory

**完了条件**: `⌘⌥⇧+V` で履歴を検索してペーストでき、再起動しても履歴が残る。

- [x] 0.8 秒間隔のポーリング監視（テキストのみ）
  - `NSPasteboard` に変更通知は無いのでポーリングしかない
  - `tolerance` を間隔の 1/4 に置き、まとめて起こしてもらう
  - 起動時点の内容は履歴に入れない（再起動のたび同じ項目が先頭へ来るのを避ける）
- [x] 重複排除（同一内容は削除して先頭へ移動）、最大 50 件
- [x] 永続化 → `~/Library/Application Support/compass/clipboard.json`
  - **パーミッションは 0600。** 履歴は機密を含みうる
  - 壊れていても起動は止めず、空から始める
- [x] **パスワードマネージャの印が付いた内容は履歴に残さない**
  - `org.nspasteboard.ConcealedType` などを見る。拾うとパスワードが平文で残る
  - 当初の要件には無い。永続化する以上必要（requirements.md 3.4 に追記した）
- [x] `SearchUI` を流用した履歴一覧
  - 複数行は 1 行に畳んで表示し、貼る中身は元のまま
- [x] `Enter` でクリップボードにセットして `Cmd+V` 送出
  - **窓を閉じてから送る。** 開いたまま送ると自分の入力欄に貼られる
- [x] `config.toml` の `clipboard.enabled = false` で監視ごと停止する
- [ ] 実機で確認する（**アクセシビリティ権限の付与が必要**）

---

## Phase 5: Snippets

**完了条件**: `⌘⌥⇧+W` でスニペットを選んでペーストでき、動的値が展開される。

- [x] `snippets.toml` のロード
- [x] 静的テキストのペースト
- [x] 組み込みプレースホルダの展開（`{date:yyyy-MM-dd}` など。プロセス起動なし）
  - [x] サポートするプレースホルダの一覧を確定する → `--print-placeholders`
    - `{date}` / `{date:<書式>}` / `{time}` / `{time:<書式>}` / `{datetime}` / `{uuid}`
    - **暦とロケールを固定する。** 端末が日本語だと `yyyy` が和暦年になりうる
    - 知らないプレースホルダはそのまま残す（`{foo}` をリテラルとして書ける）
- [x] `body_command` による外部コマンド出力の展開
  - **一覧を開いた時点では実行しない。** 副作用のあるコマンドが選ばずに走るのを避ける
  - メインスレッドを止めない。タイムアウト付きで裏で走らせ、揃ってから貼る
  - **出力を読み切ってから待つ。** 先に `waitUntilExit` するとパイプが埋まって
    互いに待ち合う
  - 末尾の改行だけ落とす（`git branch --show-current` が改行で終わる）
- [x] `SearchUI` を流用した一覧と `Enter` でのペースト
  - 一覧に「何が貼られるか」を出す（`body` は展開後、`body_command` は `$ コマンド`）
- [ ] 実機で確認する（**アクセシビリティ権限の付与が必要**）

---

## Phase 6: 移行と撤収

**完了条件**: Hammerspoon を停止しても日常の操作が成立する。

突き合わせの結果と、そのまま貼れる home-manager の設定は
[migration.md](./migration.md) にまとめた。

- [x] 現行 Hammerspoon の全ホットキーが compass 側に揃っているか突き合わせる
  - **現行設定のうち 2 つが既に壊れていた**（どちらも今は何も起動しない）
    - `⌘⌥⇧+Space` が開く `Chrome Apps.localized/Claude.app` が存在しない
      → 要件では「Claude を別のキーへ移す」としていたが、**移す対象が無い**
    - `⌘⌥⇧+Return` の MagicBoard のパスが `~/Work/dotfiles/…` のまま
- [x] 現行のクリップボード履歴を引き継ぐか、捨てるかを決める → **捨てる**
  - 数日で入れ替わる性質のもの。必要なら
    `defaults read org.hammerspoon.Hammerspoon clipboard_history` で取り出せる
- [x] スニペット（`now` / `TwitterID` / `mail`）を `snippets.toml` へ移す
  - `now` は `body = "{date}"` で表現できる
- [ ] **並行運用期間**: Hammerspoon 側のキーバインドを外し、compass だけで数日運用する
  - **Carbon のホットキー登録はプロセス間で排他にならない。** Hammerspoon が動いた
    ままでも compass 側の登録は成功する（実測）ので、外さないと両方が掴む
- [ ] 問題がなければ dotfiles から Hammerspoon 設定を削除する
- [ ] `Cmd+Space` の扱いを決める（Spotlight を戻すか、空けたままにするか）

---

## 移植しないもの

| 項目 | 理由 |
|---|---|
| `⌘⌥⇧+Delete`（ウィンドウを閉じる） | Accessibility API 依存。実行モデルを外部コマンドのみに保つため廃止 |
| インライン計算機 | 今回のスコープ外 |
| クリップボード履歴の画像・ファイル対応 | 現行相当で十分と判断 |
| 使用頻度による並び順の学習 | 同じ入力に同じ結果が返る予測可能性を優先 |
| 設定の共通/マシン固有 2 層構成 | マージは Nix の責任とし、アプリ側は単純に保つ |
| トリガー以外のキー指定・複数トリガー | 全キーを同一トリガー配下に揃え、衝突検出と他アプリとの奪い合いを単純に保つ |
