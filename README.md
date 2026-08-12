# compass

macOS ネイティブのアプリランチャー。Hammerspoon で運用しているランチャー環境を置き換える。

2 つの入口を持つ。

1. **検索窓** — `⌘⌥⇧+Space` で開き、アプリ・ファイル・Web を検索して実行する
2. **直接ホットキー** — `⌘⌥⇧+{任意キー}` で検索窓を経由せずコマンドを一発実行する

## ステータス

**Phase 0（権限検証）完了。次は Phase 1（プロジェクト基盤）。**

配布方式が確定した。**自己署名の固定証明書で署名し `~/Applications/compass.app` へコピー配置する。** nix store に本体は置かず、flake は設定・自動起動・ログの置き場所だけを受け持つ。

アクセシビリティ権限は署名の同一性に紐づくため、ad-hoc 署名だとリビルドのたびに外れる。固定証明書なら cdhash が変わっても保持されることを実機で確認した（[検証の詳細](./experiments/phase0-permission/README.md)）。Apple Developer アカウントは不要。

## ドキュメント

| | |
|---|---|
| [docs/requirements.md](./docs/requirements.md) | 要件定義。機能・設定仕様・技術選択の根拠・リスク |
| [docs/tasks.md](./docs/tasks.md) | 実装タスク。フェーズ別の進捗管理 |
| [experiments/phase0-permission/](./experiments/phase0-permission/) | Phase 0 の検証アプリと結果 |

## ビルド

```bash
# 署名 ID を作る（一度だけ。省略すると入れ替えのたびに権限を求められる）
./scripts/make-signing-cert.sh
```

初回の `codesign` で出るキーチェーンのダイアログは**「常に許可」**を選ぶ。「許可」だとビルドのたびに聞かれる。

## 設定

`~/.config/compass/` に役割別の 3 ファイルを置く。Nix / home-manager から配布する。

```
config.toml     アプリ本体の設定
hotkeys.toml    ショートカット登録
snippets.toml   スニペット登録
```

仕様は [requirements.md の 4 章](./docs/requirements.md#4-設定ファイル) を参照。
