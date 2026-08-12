# compass

macOS ネイティブのアプリランチャー。Hammerspoon で運用しているランチャー環境を置き換える。

2 つの入口を持つ。

1. **検索窓** — `⌘⌥⇧+Space` で開き、アプリ・ファイル・Web を検索して実行する
2. **直接ホットキー** — `⌘⌥⇧+{任意キー}` で検索窓を経由せずコマンドを一発実行する

## ステータス

**Phase 1〜5 の実装が完了。** 実機での操作確認と Hammerspoon からの移行が残っている。

| Phase | 内容 | 状態 |
|---|---|---|
| 0 | 権限検証 | 完了（実機確認済み） |
| 1 | プロジェクト基盤・設定ロード | 完了（launchd の登録は未確認） |
| 2 | HotkeyEngine | 完了 |
| 3 | SearchUI | 完了（見た目と操作は未確認） |
| 4 | ClipboardHistory | 完了（ペーストは未確認） |
| 5 | Snippets | 完了（ペーストは未確認） |
| 6 | 移行 | 突き合わせ済み。並行運用が残る |

配布方式は Phase 0 で確定した。**自己署名の固定証明書で署名し `~/Applications/compass.app` へコピー配置する。** nix store に本体は置かず、flake は設定・自動起動・ログの置き場所だけを受け持つ。

アクセシビリティ権限は署名の同一性に紐づくため、ad-hoc 署名だとリビルドのたびに外れる。固定証明書なら cdhash が変わっても保持されることを実機で確認した（[検証の詳細](./experiments/phase0-permission/README.md)）。Apple Developer アカウントは不要。

## ドキュメント

| | |
|---|---|
| [docs/requirements.md](./docs/requirements.md) | 要件定義。機能・設定仕様・技術選択の根拠・リスク |
| [docs/tasks.md](./docs/tasks.md) | 実装タスク。フェーズ別の進捗管理 |
| [docs/migration.md](./docs/migration.md) | Hammerspoon との突き合わせと移行手順 |
| [experiments/phase0-permission/](./experiments/phase0-permission/) | Phase 0 の検証アプリと結果 |

## 構成

```
CompassCore       設定ロード / Action 実行 / 候補の型 / fuzzy マッチ  ← UI を知らない
HotkeyEngine      Carbon のグローバルホットキー                       ← SearchUI に依存しない
SearchUI          NSPanel + NSTableView の検索窓
ClipboardHistory  ポーリング監視と永続化
Snippets          プレースホルダの展開
```

`HotkeyEngine` が `SearchUI` を知らないことをモジュール境界で担保している。将来プロセスを分けたくなったときの退路として残してある。

## 設定

`~/.config/compass/` に役割別の 3 ファイルを置く。Nix / home-manager から配布する。

```
config.toml     アプリ本体の設定
hotkeys.toml    ショートカット登録
snippets.toml   スニペット登録
```

**設定に不備があると通知センターに出て、直前の正常な設定のまま動き続ける。** 保存すると自動で読み直す（`darwin-rebuild switch` でのシンボリックリンク張り替えも検知する）。

仕様は [requirements.md の 4 章](./docs/requirements.md#4-設定ファイル) を参照。

## ビルド

```bash
# 署名 ID を作る（一度だけ。省略すると入れ替えのたびに権限を求められる）
./scripts/make-signing-cert.sh

# ~/Applications/compass.app へ入れる
./scripts/install-app.sh release

# テスト
./scripts/test.sh
```

初回の `codesign` で出るキーチェーンのダイアログは**「常に許可」**を選ぶ。「許可」だとビルドのたびに聞かれる。

Xcode は要らない（Command Line Tools だけで組める）。`scripts/env.sh` が `Testing.framework` の探索パスを補う。

## 動作を確かめる

ホットキーを押さずに窓を出せる。常用のキーが他のアプリと衝突していても確認できる。

```
--show-search [クエリ]   検索窓を出す
--show-clipboard         クリップボード履歴を出す
--show-snippets          スニペット一覧を出す
--print-apps             列挙したアプリを出して終わる
--print-keys             hotkeys.toml に書けるキー名
--print-placeholders     snippets.toml に書けるプレースホルダ
```

`COMPASS_LOG_LEVEL=debug` でログの粒度を上げられる。launchd から起動したときのログは `~/Library/Logs/compass.log`。

メニューバーにも Dock にも出ないので、動いているかは次で確かめる。

```bash
launchctl print gui/$(id -u)/org.nix-community.home.compass
```
