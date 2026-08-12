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

        .executableTarget(name: "compass", dependencies: ["CompassCore"]),

        .testTarget(name: "CompassCoreTests", dependencies: ["CompassCore"]),
    ]
)
