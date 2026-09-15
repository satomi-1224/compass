import CompassCore
import Foundation
import PluginCatalog
import Testing

@testable import PluginKit
@testable import SearchUI

@MainActor
@Suite("SearchController とプラグイン")
struct SearchControllerPluginTests {

    final class Recorder: IssueReporting {
        func report(_ issues: [ConfigIssue]) {}
        func report(title: String, body: String) {}
    }

    final class CountingPlugin: LauncherPlugin {
        let id = "sample"
        let commands = [
            PluginCommand(
                id: "sample.open",
                title: "サンプル",
                icon: .symbol("puzzlepiece.extension")
            )
        ]
        var listCalls = 0

        func list(for commandID: String) -> PluginList? {
            guard commandID == "sample.open" else { return nil }
            listCalls += 1
            return PluginList(
                placeholder: "サンプル",
                symbolName: "list.bullet",
                candidates: []
            )
        }
    }

    private func makeConfigDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("compass-search-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("plugins", isDirectory: true),
            withIntermediateDirectories: true
        )
        try #"[[snippets]]\#ntitle = "greeting"\#nbody = "hello""#.write(
            to: root.appendingPathComponent("plugins/snippets.toml"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    private func results(
        from controller: SearchController, for query: String
    ) -> [Candidate] {
        var found: [Candidate] = []
        controller.candidates(for: query) { found = $0 }
        return found
    }

    @Test("通常検索からプラグインコマンドを見つけて一覧を解決できる")
    func findsPluginCommandFromPrimarySearch() throws {
        let root = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = PluginCatalog.makeRegistry(
            configDirectory: root, reporter: Recorder())
        registry.loadConfigurations()
        let controller = SearchController(
            config: { Config() },
            plugins: registry,
            appRoots: [root.appendingPathComponent("empty-apps").path]
        )
        controller.start()

        let candidates = results(from: controller, for: "sni")

        #expect(candidates.map(\.title) == ["スニペット"])
        #expect(candidates[0].action == .invokePluginCommand("snippets"))
        let list = try #require(registry.list(for: "snippets"))
        #expect(list.candidates.map(\.title) == ["greeting"])
    }

    @Test("登録 ID を使う既存の W 設定から同じプラグイン一覧を開ける")
    func opensSamePluginFromConfiguredHotkey() throws {
        let root = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try #"[actions]\#nw = "snippets""#.write(
            to: root.appendingPathComponent("hotkeys.toml"),
            atomically: true,
            encoding: .utf8
        )

        let registry = PluginCatalog.makeRegistry(
            configDirectory: root, reporter: Recorder())
        registry.loadConfigurations()
        let store = ConfigStore(
            directory: root,
            pluginActions: registry.commandIDs,
            reporter: Recorder()
        )
        #expect(store.load().isEmpty)
        let binding = try #require(store.hotkeys.bindings.first { $0.key == "w" })
        #expect(binding.action == .plugin("snippets"))

        let controller = SearchController(
            config: { store.config }, plugins: registry, appRoots: [])
        defer { controller.dismiss(restoringFocus: false) }
        guard case .plugin(let commandID) = binding.action else {
            Issue.record("プラグインコマンドとして解決されなかった")
            return
        }
        #expect(controller.togglePluginCommand(commandID))
        #expect(controller.isShowing(.plugin("snippets")))
    }

    @Test("アプリとコマンドをまとめて順位付けして共通の件数上限を使う")
    func ranksAppsAndCommandsTogether() throws {
        let root = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(
            at: apps.appendingPathComponent("Snippets Archive.app", isDirectory: true),
            withIntermediateDirectories: true
        )

        let registry = PluginCatalog.makeRegistry(
            configDirectory: root, reporter: Recorder())
        var config = Config()
        config.appearance.maxResults = 1
        let controller = SearchController(
            config: { config }, plugins: registry, appRoots: [apps.path])
        controller.start()

        let candidates = results(from: controller, for: "sni")
        #expect(candidates.count == 1)
        #expect(candidates[0].action == .invokePluginCommand("snippets"))
    }

    @Test("日本語名と別名のどちらでも見つかる")
    func findsCommandByTitleAndAlias() throws {
        let root = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = PluginCatalog.makeRegistry(
            configDirectory: root, reporter: Recorder())
        let controller = SearchController(
            config: { Config() }, plugins: registry, appRoots: [])
        controller.start()

        #expect(results(from: controller, for: "スニペット").count == 1)
        #expect(results(from: controller, for: "snippet").count == 1)
        #expect(results(from: controller, for: "定型文").count == 1)
    }

    @Test("キーワード検索にはプラグインコマンドを混ぜない")
    func keepsKeywordModesSeparate() throws {
        let root = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = PluginCatalog.makeRegistry(
            configDirectory: root, reporter: Recorder())
        let controller = SearchController(
            config: { Config() }, plugins: registry, appRoots: [])
        controller.start()

        let candidates = results(from: controller, for: "g snippets")

        #expect(candidates.count == 1)
        #expect(candidates[0].id == "web:g")
    }

    @Test("空入力ではプラグインコマンドを全件表示しない")
    func emptyQueryDoesNotDumpCommands() throws {
        let root = try makeConfigDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = PluginCatalog.makeRegistry(
            configDirectory: root, reporter: Recorder())
        let controller = SearchController(
            config: { Config() }, plugins: registry, appRoots: [])
        controller.start()

        #expect(results(from: controller, for: "").isEmpty)
    }

    @Test("本体一覧と同じ ID でも入口を混同せず、閉じる際は候補を作り直さない")
    func keepsPluginPresentationIdentitySeparate() {
        let plugin = CountingPlugin()
        let registry = PluginRegistry(plugins: [plugin], reporter: Recorder())
        let controller = SearchController(
            config: { Config() }, plugins: registry, appRoots: [])
        defer { controller.dismiss(restoringFocus: false) }

        #expect(controller.togglePluginCommand("sample.open"))
        #expect(controller.isShowing(.plugin("sample.open")))
        #expect(controller.isShowing(.list("sample.open")) == false)
        #expect(plugin.listCalls == 1)

        #expect(controller.togglePluginCommand("sample.open"))
        #expect(controller.isVisible == false)
        #expect(plugin.listCalls == 1)
    }
}
