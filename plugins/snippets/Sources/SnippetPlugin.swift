import CompassCore
import Foundation
import PluginKit

/// スニペットの設定、検索コマンド、一覧生成をひとまとめにしたプラグイン。
@MainActor
public final class SnippetPlugin: LauncherPlugin {

    public nonisolated static let identifier = "snippets"
    public nonisolated static let configurationFile = ConfigFile("plugins/snippets.toml")

    public let id = SnippetPlugin.identifier
    public let commands = [
        PluginCommand(
            id: SnippetPlugin.identifier,
            title: "スニペット",
            subtitle: "登録したテキストを選んで貼り付け",
            icon: .symbol("text.badge.plus"),
            aliases: ["snippet", "snippets", "定型文"],
            requiresAccessibility: true
        )
    ]

    public private(set) var configurationIssues: [ConfigIssue] = []
    public private(set) var definitions: [SnippetDefinition] = []

    private let configDirectory: URL
    private var watcher: ConfigWatcher?

    public init(configDirectory: URL) {
        self.configDirectory = configDirectory
    }

    public var count: Int { definitions.count }

    /// 読めたときだけ差し替える。壊れた設定では直前の正常値を保つ。
    public func loadConfiguration() {
        let url = configDirectory.appendingPathComponent(Self.configurationFile.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            definitions = []
            configurationIssues = []
            return
        }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            definitions = try SnippetDefinition.parseAll(text)
            configurationIssues = []
        } catch let issues as ConfigIssues {
            configurationIssues = issues.items
        } catch {
            configurationIssues = [
                ConfigIssue(
                    file: Self.configurationFile,
                    detail: "読み込めない: \(error.localizedDescription)"
                )
            ]
        }
    }

    @discardableResult
    public func startWatchingConfiguration(
        onChange: @escaping @MainActor () -> Void
    ) -> Bool {
        guard watcher == nil else { return true }

        let directory = configDirectory.appendingPathComponent("plugins", isDirectory: true)
        let watcher = ConfigWatcher(
            directory: directory.path,
            fileNames: ["snippets.toml"]
        )
        watcher.onChange = { [weak self] in
            guard let self else { return }
            self.loadConfiguration()
            onChange()
        }
        guard watcher.start() else {
            watcher.stop()
            return false
        }
        self.watcher = watcher
        return true
    }

    public func stopWatchingConfiguration() {
        watcher?.stop()
        watcher = nil
    }

    public func list(for commandID: String) -> PluginList? {
        guard commandID == Self.identifier else { return nil }
        let library = SnippetLibrary(definitions: { [weak self] in self?.definitions ?? [] })
        return PluginList(
            placeholder: "スニペット",
            symbolName: "text.badge.plus",
            candidates: library.candidates()
        )
    }
}
