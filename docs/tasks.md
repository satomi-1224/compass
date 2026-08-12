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

- [ ] Swift パッケージ構成を切る（`CompassCore` / `HotkeyEngine` / `SearchUI` / `ClipboardHistory` / `Snippets`）
  - `HotkeyEngine` が `SearchUI` に依存しないことをモジュール境界で担保する
- [ ] `.app` バンドルの生成（`Info.plist`、`LSUIElement = true` で Dock 非表示）
- [ ] `scripts/build-app.sh` — `swift build` → バンドル組み立て → `compass-dev` で署名
  - 署名 ID が無ければ ad-hoc に落とし、**権限が外れる旨を警告する**
- [ ] `scripts/install-app.sh` — `~/Applications/compass.app` へ入れ替え、launchd を読み直す
  - 動いているプロセスは先に止める。バンドルを差し替えると署名の検証に失敗して落ちる
  - `bootout` したら必ず `bootstrap` で戻す（戻さないと登録が消えて `kickstart` が失敗する）
- [ ] flake で home-manager モジュールを提供する
  - 受け持つのは**設定・自動起動・ログの置き場所のみ**。本体は store に置かない

> **却下**: 「Nix flake で `.app` までビルドする」は Phase 0 の結論により採らない（requirements.md 5.1）。

### 設定

- [ ] TOML パーサを導入する（[dduan/TOMLDecoder](https://github.com/dduan/TOMLDecoder) に決定。comet と揃える）
- [ ] `config.toml` / `hotkeys.toml` / `snippets.toml` のスキーマを型として定義
  - `hotkeys.toml` は `trigger` 1 行 + `[actions]` + `[commands]` のセクション分割
- [ ] 3 ファイルのロード処理（ファイル欠損は空として扱い、エラーにしない）
- [ ] バリデーション
  - [ ] 不明なキー名、必須項目の欠落
  - [ ] **`[actions]` と `[commands]` の間のキー衝突**（同じキーが両方にある）
  - [ ] `[actions]` の値が組み込みアクション名（`search` / `clipboard` / `snippets`）であること
- [ ] **エラー時は直前の正常な設定を保持して動き続ける**
- [ ] エラーのみ通知センターに出す（正常時は完全に無音）
- [ ] ファイル監視による自動リロード
  - `darwin-rebuild switch` でのシンボリックリンク張り替えを検知できることを実機確認する

### 常駐

- [ ] launchd エージェントでログイン時に自動起動し、落ちても復帰する
- [ ] メニューバーにも Dock にも一切出ないことを確認
- [ ] 最小のメインメニュー（Edit）を組む
  - **`NSApp.mainMenu` が無いと `Cmd+V` が `paste:` に解決されない**（Phase 0 で実測）。`LSUIElement = true` でメニューバーを出さなくても設定自体は必要（requirements.md 7.4）

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

- [ ] `NSPanel` + SwiftUI で検索窓を作る（非アクティブ化で閉じる、Esc で閉じる）
- [ ] 常にメインディスプレイの上寄り中央に出す
- [ ] 外観を詰める（角丸・ブラー・行の高さ・アイコンサイズ）※未確定事項

### 検索

- [ ] fuzzy マッチングの実装（頻度学習は**行わない**）
- [ ] キーワード切替のパース（先頭トークンで判定、以降をクエリとして扱う）
- [ ] アプリ検索（`NSMetadataQuery` でアプリバンドルを列挙）
  - [ ] `~/Applications/Chrome Apps.localized/` 配下の PWA が拾えることを確認（現行の積み残し）
  - [ ] アプリ名の日本語・かなマッチングの扱いを決める ※未確定事項
- [ ] ファイル検索（`NSMetadataQuery`、探索範囲は config の `scopes`）
- [ ] Web 検索（URL テンプレートの `{query}` を置換してブラウザ起動）
  - [ ] デフォルトキーワードを決める（`g` = Google、`gh` = GitHub を想定）※未確定事項
- [ ] `Enter` で実行（修飾キーによる副アクションは持たない）

---

## Phase 4: ClipboardHistory

**完了条件**: `⌘⌥⇧+V` で履歴を検索してペーストでき、再起動しても履歴が残る。

- [ ] 0.8 秒間隔のポーリング監視（テキストのみ）
- [ ] 重複排除（同一内容は削除して先頭へ移動）、最大 50 件
- [ ] 永続化（現行 `hs.settings` 相当。保存先を決める）
- [ ] `SearchUI` を流用した履歴一覧
- [ ] `Enter` でクリップボードにセットして `Cmd+V` 送出
- [ ] `config.toml` の `clipboard.enabled = false` で監視ごと停止することを確認

---

## Phase 5: Snippets

**完了条件**: `⌘⌥⇧+W` でスニペットを選んでペーストでき、動的値が展開される。

- [ ] `snippets.toml` のロード
- [ ] 静的テキストのペースト
- [ ] 組み込みプレースホルダの展開（`{date:yyyy-MM-dd}` など。プロセス起動なし）
  - [ ] サポートするプレースホルダの一覧を確定する
- [ ] `body_command` による外部コマンド出力の展開
- [ ] `SearchUI` を流用した一覧と `Enter` でのペースト

---

## Phase 6: 移行と撤収

**完了条件**: Hammerspoon を停止しても日常の操作が成立する。

- [ ] 現行 Hammerspoon の全ホットキーが compass 側に揃っているか突き合わせる
- [ ] 現行のクリップボード履歴を引き継ぐか、捨てるかを決める
- [ ] スニペット（`now` / `TwitterID` / `mail`）を `snippets.toml` へ移す
- [ ] **並行運用期間**: Hammerspoon 側のキーバインドを外し、compass だけで数日運用する
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
