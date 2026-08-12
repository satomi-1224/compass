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

        // 検索窓。クリップボード履歴とスニペット一覧もこの UI を流用する
        // （requirements.md 6章）。
        .target(name: "SearchUI", dependencies: ["CompassCore"]),

        // 全コピー内容をディスクに永続化するという責務の性質がランチャーと異なるため
        // 独立させてある。丸ごと切り離す判断に備える（requirements.md 2章）。
        .target(name: "ClipboardHistory", dependencies: ["CompassCore"]),

        .target(name: "Snippets", dependencies: ["CompassCore"]),

        .executableTarget(
            name: "compass",
            dependencies: [
                "CompassCore", "HotkeyEngine", "SearchUI", "ClipboardHistory", "Snippets",
            ]
        ),

        .testTarget(name: "CompassCoreTests", dependencies: ["CompassCore"]),
        .testTarget(name: "HotkeyEngineTests", dependencies: ["HotkeyEngine"]),
        .testTarget(name: "SearchUITests", dependencies: ["SearchUI"]),
        .testTarget(name: "ClipboardHistoryTests", dependencies: ["ClipboardHistory"]),
        .testTarget(name: "SnippetsTests", dependencies: ["Snippets"]),
    ]
)
