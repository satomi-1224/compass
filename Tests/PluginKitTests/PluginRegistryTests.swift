import CompassCore
import Testing

@testable import PluginKit

@MainActor
@Suite("PluginRegistry")
struct PluginRegistryTests {

    final class Recorder: IssueReporting {
        var issues: [ConfigIssue] = []
        var messages: [(title: String, body: String)] = []

        func report(_ issues: [ConfigIssue]) { self.issues.append(contentsOf: issues) }
        func report(title: String, body: String) { messages.append((title, body)) }
    }

    final class StubPlugin: LauncherPlugin {
        let id: String
        let commands: [PluginCommand]
        var configurationIssues: [ConfigIssue]
        var listCalls = 0

        init(
            id: String,
            commands: [PluginCommand],
            configurationIssues: [ConfigIssue] = []
        ) {
            self.id = id
            self.commands = commands
            self.configurationIssues = configurationIssues
        }

        func list(for commandID: String) -> PluginList? {
            guard commands.contains(where: { $0.id == commandID }) else { return nil }
            listCalls += 1
            return PluginList(
                placeholder: "一覧",
                symbolName: "list.bullet",
                candidates: [
                    Candidate(
                        id: "item",
                        title: "項目",
                        icon: .symbol("doc"),
                        action: .paste("value")
                    )
                ]
            )
        }
    }

    private func command(
        _ id: String = "sample.open", title: String = "サンプル"
    ) -> PluginCommand {
        PluginCommand(
            id: id,
            title: title,
            subtitle: "プラグインコマンド",
            icon: .symbol("puzzlepiece.extension"),
            aliases: ["sample"]
        )
    }

    @Test("登録したコマンドを検索候補と一覧の両方から引ける")
    func exposesCommandAndList() throws {
        let plugin = StubPlugin(id: "sample", commands: [command()])
        let registry = PluginRegistry(plugins: [plugin], reporter: Recorder())

        let candidate = try #require(registry.commandCandidates.first)
        #expect(candidate.id == "plugin-command:sample.open")
        #expect(candidate.action == .invokePluginCommand("sample.open"))
        #expect(candidate.aliases == ["sample"])

        let list = try #require(registry.list(for: "sample.open"))
        #expect(list.candidates.map(\.title) == ["項目"])
        #expect(plugin.listCalls == 1)
    }

    @Test("アクセシビリティ要否はコマンド定義から引く")
    func exposesAccessibilityRequirement() {
        let descriptor = PluginCommand(
            id: "sample.paste",
            title: "貼り付け",
            icon: .symbol("doc.on.clipboard"),
            requiresAccessibility: true
        )
        let registry = PluginRegistry(
            plugins: [StubPlugin(id: "sample", commands: [descriptor])],
            reporter: Recorder()
        )

        #expect(registry.requiresAccessibility(for: "sample.paste"))
        #expect(registry.requiresAccessibility(for: "missing") == false)
        #expect(registry.hasAccessibilityDependentCommands)

        let independent = PluginRegistry(
            plugins: [StubPlugin(id: "sample", commands: [command()])],
            reporter: Recorder()
        )
        #expect(independent.hasAccessibilityDependentCommands == false)
    }

    @Test("重複したプラグイン ID は後続を丸ごと登録しない")
    func rejectsDuplicatePluginIDs() {
        let registry = PluginRegistry(
            plugins: [
                StubPlugin(id: "same", commands: [command("first")]),
                StubPlugin(id: "same", commands: [command("second")]),
            ],
            reporter: Recorder()
        )

        #expect(registry.commandIDs == ["first"])
        #expect(registry.registrationIssues.count == 1)
        #expect(registry.registrationIssues[0].detail.contains("プラグイン ID が重複"))
    }

    @Test("重複したコマンド ID は最初の登録だけを残して報告する")
    func rejectsDuplicateCommandIDs() {
        let recorder = Recorder()
        let first = StubPlugin(id: "first", commands: [command("shared")])
        let second = StubPlugin(id: "second", commands: [command("shared")])
        let registry = PluginRegistry(plugins: [first, second], reporter: recorder)

        #expect(registry.commandCount == 1)
        #expect(registry.registrationIssues.count == 1)
        #expect(registry.registrationIssues[0].detail.contains("shared"))
        #expect(recorder.messages.count == 1)
    }

    @Test("本体アクションと同じ ID は登録しない")
    func rejectsReservedCommandIDs() {
        let registry = PluginRegistry(
            plugins: [StubPlugin(id: "sample", commands: [command("search")])],
            reservedCommandIDs: ["search"],
            reporter: Recorder()
        )

        #expect(registry.commandCount == 0)
        #expect(registry.registrationIssues.count == 1)
    }

    @Test("ID と title の不備を全て集める")
    func validatesRegistrationMetadata() {
        let invalidID = StubPlugin(id: "Bad ID", commands: [command()])
        let invalidCommands = StubPlugin(
            id: "valid",
            commands: [command("Bad Command"), command("empty-title", title: "  ")]
        )
        let registry = PluginRegistry(
            plugins: [invalidID, invalidCommands], reporter: Recorder())

        #expect(registry.commandCount == 0)
        #expect(registry.registrationIssues.count == 3)
    }

    @Test("設定不備はファイル名順で集約して通知する")
    func collectsConfigurationIssuesDeterministically() {
        let recorder = Recorder()
        let plugin = StubPlugin(
            id: "sample",
            commands: [command()],
            configurationIssues: [
                ConfigIssue(file: ConfigFile("plugins/z.toml"), detail: "z"),
                ConfigIssue(file: ConfigFile("plugins/a.toml"), detail: "a"),
            ]
        )
        let registry = PluginRegistry(plugins: [plugin], reporter: recorder)

        let issues = registry.loadConfigurations()

        #expect(issues.map(\.file.fileName) == ["plugins/a.toml", "plugins/z.toml"])
        #expect(recorder.issues == issues)
    }
}
