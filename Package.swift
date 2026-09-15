// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "compass",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Swift 標準に TOML パーサは無い。Codable 対応の純 Swift 実装を使う
        // （requirements.md 6章。comet と揃えている）。
        .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5")
    ],
    targets: [
        // 設定のロードと Action の実行。他のどのモジュールにも依存しない土台。
        // **UI を知らない。** ここに AppKit の表示を持ち込まないこと。
        .target(
            name: "CompassCore",
            dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]
        ),

        // グローバルホットキーの登録。**SearchUI に依存させない。**
        // 将来プロセスを分けたくなったときの退路を、モジュール境界で残しておく。
        .target(name: "HotkeyEngine", dependencies: ["CompassCore"]),

        // プラグインが検索へ公開するコマンドと、実行時の一覧を結ぶ契約。
        // SearchUI を知らないため、プラグインから UI 実装への依存は生まれない。
        .target(name: "PluginKit", dependencies: ["CompassCore"]),

        // 検索窓。クリップボード履歴とプラグインの一覧もこの UI を流用する
        // （requirements.md 6章）。
        .target(name: "SearchUI", dependencies: ["CompassCore", "PluginKit"]),

        // 全コピー内容をディスクに永続化するという責務の性質がランチャーと異なるため
        // 独立させてある。丸ごと切り離す判断に備える（requirements.md 2章）。
        .target(name: "ClipboardHistory", dependencies: ["CompassCore"]),

        // 個々のプラグインはリポジトリ直下の plugins/ に置く。
        .target(
            name: "SnippetsPlugin",
            dependencies: [
                "CompassCore", "PluginKit",
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
            ],
            path: "plugins/snippets/Sources"
        ),

        // 本体が知る登録口を 1 箇所に保つ。プラグイン追加時はここだけを更新する。
        .target(
            name: "PluginCatalog",
            dependencies: ["CompassCore", "PluginKit", "SnippetsPlugin"],
            path: "plugins/catalog/Sources"
        ),

        .executableTarget(
            name: "compass",
            dependencies: [
                "CompassCore", "HotkeyEngine", "SearchUI", "ClipboardHistory", "PluginKit",
                "PluginCatalog",
            ]
        ),

        .testTarget(name: "CompassCoreTests", dependencies: ["CompassCore"]),
        .testTarget(name: "HotkeyEngineTests", dependencies: ["HotkeyEngine"]),
        .testTarget(name: "PluginKitTests", dependencies: ["CompassCore", "PluginKit"]),
        .testTarget(
            name: "SearchUITests",
            dependencies: ["SearchUI", "PluginKit", "PluginCatalog", "CompassCore"]
        ),
        .testTarget(name: "ClipboardHistoryTests", dependencies: ["ClipboardHistory"]),
        .testTarget(
            name: "SnippetsPluginTests",
            dependencies: ["CompassCore", "PluginKit", "SnippetsPlugin"],
            path: "Tests/SnippetsTests"
        ),
    ]
)
