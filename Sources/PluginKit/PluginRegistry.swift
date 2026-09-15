import CompassCore
import Foundation

/// 登録時に見つかった、コード側で直すべき不備。
public struct PluginRegistrationIssue: Equatable, Sendable, CustomStringConvertible {
    public var detail: String

    public init(_ detail: String) {
        self.detail = detail
    }

    public var description: String { detail }
}

/// プラグインと検索可能なコマンドを一元管理する。
@MainActor
public final class PluginRegistry {

    private struct RegisteredCommand {
        var descriptor: PluginCommand
        var plugin: any LauncherPlugin
    }

    private var plugins: [any LauncherPlugin] = []
    private let reporter: any IssueReporting
    private var commandByID: [String: RegisteredCommand] = [:]
    private var orderedCommands: [PluginCommand] = []

    public private(set) var registrationIssues: [PluginRegistrationIssue] = []
    public private(set) var issues: [ConfigIssue] = []
    public var onChange: (@MainActor () -> Void)?

    /// - Parameter reservedCommandIDs: 本体アクションと衝突してはいけない識別子。
    public init(
        plugins candidates: [any LauncherPlugin] = [],
        reservedCommandIDs: Set<String> = [],
        reporter: any IssueReporting = Notifier.shared
    ) {
        self.reporter = reporter

        var accepted: [any LauncherPlugin] = []
        var pluginIDs = Set<String>()
        var commandIDs = reservedCommandIDs

        for plugin in candidates {
            guard Self.isValidIdentifier(plugin.id) else {
                registrationIssues.append(
                    PluginRegistrationIssue("プラグイン ID が不正: \(plugin.id)"))
                continue
            }
            guard pluginIDs.insert(plugin.id).inserted else {
                registrationIssues.append(
                    PluginRegistrationIssue("プラグイン ID が重複: \(plugin.id)"))
                continue
            }
            accepted.append(plugin)

            for command in plugin.commands {
                guard Self.isValidIdentifier(command.id) else {
                    registrationIssues.append(
                        PluginRegistrationIssue(
                            "\(plugin.id) のコマンド ID が不正: \(command.id)"))
                    continue
                }
                guard !command.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    registrationIssues.append(
                        PluginRegistrationIssue(
                            "\(plugin.id) のコマンド \(command.id) に title が無い"))
                    continue
                }
                guard commandIDs.insert(command.id).inserted else {
                    registrationIssues.append(
                        PluginRegistrationIssue("コマンド ID が重複: \(command.id)"))
                    continue
                }
                let registered = RegisteredCommand(descriptor: command, plugin: plugin)
                commandByID[command.id] = registered
                orderedCommands.append(command)
            }
        }

        self.plugins = accepted

        if !registrationIssues.isEmpty {
            reporter.report(
                title: "プラグインを登録できなかった",
                body: registrationIssues.map(\.detail).joined(separator: "\n")
            )
        }
    }

    /// 登録済みコマンドの ID。ホットキー設定の検証にも同じ集合を使う。
    public var commandIDs: Set<String> { Set(commandByID.keys) }

    /// 通常検索へ混ぜる候補。登録順を保ち、並び替えは検索側へ一任する。
    public var commandCandidates: [Candidate] { orderedCommands.map(\.candidate) }

    public var commandCount: Int { orderedCommands.count }

    /// 通常検索から利用できるコマンドに、アクセシビリティ権限を使うものがあるか。
    ///
    /// ホットキーへ割り当てられていなくても通常検索から実行できるため、権限案内の要否を
    /// ホットキー設定だけで決めてはいけない。
    public var hasAccessibilityDependentCommands: Bool {
        orderedCommands.contains(where: \.requiresAccessibility)
    }

    public func list(for commandID: String) -> PluginList? {
        guard let registered = commandByID[commandID] else { return nil }
        return registered.plugin.list(for: commandID)
    }

    public func requiresAccessibility(for commandID: String) -> Bool {
        commandByID[commandID]?.descriptor.requiresAccessibility == true
    }

    // MARK: - 設定

    /// 全プラグインの設定を読む。不備があるプラグインは自身の直前正常値を保つ。
    @discardableResult
    public func loadConfigurations() -> [ConfigIssue] {
        for plugin in plugins { plugin.loadConfiguration() }
        collectConfigurationIssues(reporting: true)
        return issues
    }

    /// 各プラグインの設定監視を開始する。
    ///
    /// - Returns: 全て開始できたか。設定を持たないプラグインは成功扱い。
    @discardableResult
    public func startWatching() -> Bool {
        var allStarted = true
        for plugin in plugins {
            let started = plugin.startWatchingConfiguration { [weak self] in
                self?.configurationDidChange()
            }
            allStarted = started && allStarted
        }
        return allStarted
    }

    public func stopWatching() {
        for plugin in plugins { plugin.stopWatchingConfiguration() }
    }

    private func configurationDidChange() {
        collectConfigurationIssues(reporting: true)
        onChange?()
    }

    private func collectConfigurationIssues(reporting shouldReport: Bool) {
        issues = plugins.flatMap(\.configurationIssues)
            .sorted {
                if $0.file.fileName != $1.file.fileName {
                    return $0.file.fileName < $1.file.fileName
                }
                return $0.detail < $1.detail
            }
        if shouldReport, !issues.isEmpty {
            reporter.report(issues)
        }
    }

    /// 設定で安全に参照できる、小文字 ASCII の安定した ID だけを受け付ける。
    private static func isValidIdentifier(_ value: String) -> Bool {
        guard let first = value.utf8.first,
            (first >= 0x61 && first <= 0x7A) || (first >= 0x30 && first <= 0x39)
        else { return false }

        return value.utf8.dropFirst().allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2E
                || byte == 0x2D
                || byte == 0x5F
        }
    }
}
