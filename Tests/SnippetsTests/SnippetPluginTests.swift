import Foundation
import Testing

@testable import CompassCore
@testable import PluginKit
@testable import SnippetsPlugin

@MainActor
@Suite("SnippetPlugin")
struct SnippetPluginTests {

    private func makeConfigDirectory(createPluginDirectory: Bool = true) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("compass-snippets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if createPluginDirectory {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("plugins", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return root
    }

    private func write(_ text: String, to root: URL) throws {
        try text.write(
            to: root.appendingPathComponent(SnippetPlugin.configurationFile.fileName),
            atomically: true,
            encoding: .utf8
        )
    }

    @Test("plugins ディレクトリの設定から一覧を作る")
    func loadsConfigurationAndBuildsList() throws {
        let root = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(#"[[snippets]]\#ntitle = "now"\#nbody = "{date:yyyy}""#, to: root)

        let plugin = SnippetPlugin(configDirectory: root)
        plugin.loadConfiguration()

        #expect(plugin.configurationIssues.isEmpty)
        #expect(plugin.count == 1)
        let list = try #require(plugin.list(for: "snippets"))
        #expect(list.candidates.map(\.title) == ["now"])
        guard case .paste(let expanded) = list.candidates[0].action else {
            Issue.record("テキストの貼り付け候補ではない")
            return
        }
        #expect(expanded.wholeMatch(of: /\d{4}/) != nil)
    }

    @Test("壊れた設定では直前の正常値を保つ")
    func keepsLastGoodConfiguration() throws {
        let root = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = SnippetPlugin(configDirectory: root)

        try write(#"[[snippets]]\#ntitle = "safe"\#nbody = "value""#, to: root)
        plugin.loadConfiguration()
        try write(#"[[snippets]]\#ntitle = "broken""#, to: root)
        plugin.loadConfiguration()

        #expect(plugin.definitions.map(\.title) == ["safe"])
        #expect(plugin.configurationIssues.count == 1)
        #expect(
            plugin.configurationIssues[0].file.fileName == "plugins/snippets.toml")
    }

    @Test("設定ファイルが消えたら空へ戻す")
    func missingConfigurationResetsDefinitions() throws {
        let root = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = SnippetPlugin(configDirectory: root)

        try write(#"[[snippets]]\#ntitle = "one"\#nbody = "1""#, to: root)
        plugin.loadConfiguration()
        try FileManager.default.removeItem(
            at: root.appendingPathComponent(SnippetPlugin.configurationFile.fileName))
        plugin.loadConfiguration()

        #expect(plugin.definitions.isEmpty)
        #expect(plugin.configurationIssues.isEmpty)
    }

    @Test("自分以外のコマンド ID は解決しない")
    func ignoresUnknownCommand() {
        let plugin = SnippetPlugin(configDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(plugin.list(for: "unknown") == nil)
    }

    @Test("設定ファイルの作成を監視して再読込する")
    func watchesConfigurationCreation() async throws {
        let root = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = SnippetPlugin(configDirectory: root)
        var changes = 0

        #expect(plugin.startWatchingConfiguration { changes += 1 })
        defer { plugin.stopWatchingConfiguration() }
        try write(#"[[snippets]]\#ntitle = "watched"\#nbody = "value""#, to: root)

        try await Task.sleep(for: .milliseconds(700))
        #expect(changes == 1)
        #expect(plugin.definitions.map(\.title) == ["watched"])
    }

    @Test("設定ルートごと無い初回起動から復帰する")
    func watchesFromMissingConfigurationRoot() async throws {
        let base = try makeConfigDirectory(createPluginDirectory: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("compass", isDirectory: true)
        let plugin = SnippetPlugin(configDirectory: root)
        var changes = 0

        #expect(plugin.startWatchingConfiguration { changes += 1 })
        defer { plugin.stopWatchingConfiguration() }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("plugins", isDirectory: true),
            withIntermediateDirectories: true
        )
        try write(#"[[snippets]]\#ntitle = "late"\#nbody = "value""#, to: root)

        try await Task.sleep(for: .milliseconds(700))
        #expect(changes >= 1)
        #expect(plugin.definitions.map(\.title) == ["late"])
    }
}
