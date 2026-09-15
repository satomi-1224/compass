# plugins

同梱プラグインの実装と登録口を置くディレクトリ。

```text
plugins/
├─ catalog/    アプリへ同梱するプラグインの登録
└─ snippets/   スニペット機能
```

追加時は `LauncherPlugin` を実装し、`Package.swift` にターゲットを足してから
`catalog/Sources/PluginCatalog.swift` の配列へ登録する。コマンド ID は通常検索と
`hotkeys.toml` の `[actions]` で共用される。

設定を持つ場合は `~/.config/compass/plugins/<id>.toml` を使い、Nix オプションも
`programs.compass.plugins.<id>` の下に置く。詳しい不変条件と実行経路は
[プラグイン設計](../docs/plugin-architecture.md) を参照。
