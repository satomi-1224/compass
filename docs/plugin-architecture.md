# プラグイン設計

## 目的

検索とホットキーを入口として保ったまま、機能ごとの設定・候補生成・一覧を本体から
分離する。追加機能は通常検索で見つかり、必要なら同じコマンド ID をホットキーへ
割り当てられる。

## 境界

```text
通常検索 ─┐
          ├─ PluginRegistry ─ PluginCommand ─ PluginList ─ CandidateAction
ホットキー ┘                        │
                                    └─ plugins/<id>/
```

- `CompassCore` は候補、アクション、本体設定、ホットキーを持つ。
- `PluginKit` は `LauncherPlugin`、検索可能な `PluginCommand`、表示する `PluginList`、
  それらを検証して引く `PluginRegistry` を持つ。`SearchUI` には依存しない。
- `SearchUI` はアプリ候補とプラグインコマンドを同じ集合にして一度だけ順位付けする。
- `plugins/catalog` は同梱する実装の唯一の登録口とする。
- 各 `plugins/<id>` は固有の設定型、設定読込、候補生成を自身で持つ。

本体がプラグイン固有の型を知らないことを優先する。新しいコマンドを追加しても
`BuiltinAction` や `SearchController` の switch は増やさない。

## コマンドの流れ

通常検索では、登録済み `PluginCommand` を `Candidate` に変換し、アプリ候補とまとめて
fuzzy マッチへ渡す。先に種類別の上限を掛けないため、候補種別による順位の偏りはない。

候補を選ぶと `invokePluginCommand(id)` がレジストリへ戻り、その時点の設定から一覧を作る。
ホットキーの `[actions]` も同じ ID を引く。スニペットなら検索経由でも `W` 経由でも、
最終的に `SnippetPlugin.list(for: "snippets")` へ到達する。

## 登録時の不変条件

- プラグイン ID とコマンド ID は小文字 ASCII の安定した識別子にする。
- プラグイン ID はプラグイン間で一意にする。
- コマンド ID は全プラグイン間で一意にし、本体アクション ID と重複させない。
- コマンド定義はプロセスの起動中に増減させない。設定変更では一覧の候補だけを更新する。
- 検索へ公開するコマンドには空でない title と必ずアイコンを持たせる。
- 一覧生成では外部コマンドなどの副作用を起こさず、選択後の `CandidateAction` へ遅延する。
- アクセシビリティ権限が必要かはコマンド単位で宣言する。
- 通常検索からも実行できるため、権限案内の要否はホットキーへの割り当てだけで決めない。
- 登録不備は全件をまとめてログと通知へ出し、競合した後続コマンドは公開しない。

## 設定

プラグイン設定は次の形にそろえる。

```text
~/.config/compass/
├─ config.toml
├─ hotkeys.toml
└─ plugins/
   └─ <plugin-id>.toml
```

パース、直前正常値の保持、ファイル監視は各プラグインの責務にする。本体は各プラグインの
`configurationIssues` だけを集約する。これにより、新しい設定ファイルを追加しても
`ConfigStore` や本体側の設定ファイル一覧を変更しない。

Nix のオプションも `programs.compass.plugins.<id>` に置き、生成先と実装の所有境界を
一致させる。スニペットの旧オプション名は renamed option として移行できるようにする。

## 追加手順

1. `plugins/<id>/Sources` に `LauncherPlugin` 実装を置く。
2. `Package.swift` に実装ターゲットを追加する。
3. `plugins/catalog` の配列へ 1 件登録する。
4. 設定を持つ場合は `programs.compass.plugins.<id>` と `<id>.toml` の生成を追加する。
5. 登録検証、通常検索、ホットキー、設定失敗時の保持、監視をテストする。

## 今回の非目標

- 実行中に未知のバイナリを読み込む仕組み
- ネットワーク経由の配布や更新
- プラグインごとの独自ウィンドウ

まずコンパイル時登録と共通一覧に限定し、実行権限と UI の境界を小さく保つ。
