import CompassCore
import Foundation
import PluginKit
import SnippetsPlugin

/// アプリへ同梱するプラグインの唯一の登録箇所。
///
/// 新しいプラグインは実装ターゲットを `plugins/` に追加し、この配列へ登録する。
public enum PluginCatalog {

    @MainActor
    public static func makeRegistry(
        configDirectory: URL,
        reporter: any IssueReporting = Notifier.shared
    ) -> PluginRegistry {
        let plugins: [any LauncherPlugin] = [
            SnippetPlugin(configDirectory: configDirectory)
        ]
        return PluginRegistry(
            plugins: plugins,
            reservedCommandIDs: Set(BuiltinAction.allCases.map(\.rawValue)),
            reporter: reporter
        )
    }

    /// 既存のコマンドライン入口を、具体的なプラグイン型を本体へ公開せずに保つ。
    public static var snippetPlaceholders: [(syntax: String, meaning: String)] {
        SnippetExpander.placeholders
    }
}
