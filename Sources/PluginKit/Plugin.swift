import CompassCore
import Foundation

/// 通常検索へ公開するプラグインコマンド。
///
/// コマンドは表示情報だけを持つ。選ばれた時点の最新状態から一覧を作るため、実行内容は
/// `LauncherPlugin.list(for:)` で解決する。
public struct PluginCommand: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: CandidateIcon
    public var aliases: [String]
    /// ペーストなどでアクセシビリティ権限を使うか。
    public var requiresAccessibility: Bool

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        icon: CandidateIcon,
        aliases: [String] = [],
        requiresAccessibility: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.aliases = aliases
        self.requiresAccessibility = requiresAccessibility
    }

    /// アプリ候補と同じ検索パイプラインへ流す形。
    public var candidate: Candidate {
        Candidate(
            id: "plugin-command:\(id)",
            title: title,
            subtitle: subtitle,
            icon: icon,
            action: .invokePluginCommand(id),
            aliases: aliases
        )
    }
}

/// プラグインコマンドを選んだあとに表示する一覧。
public struct PluginList: Equatable, Sendable {
    public var placeholder: String
    public var symbolName: String
    public var candidates: [Candidate]

    public init(
        placeholder: String, symbolName: String, candidates: [Candidate]
    ) {
        self.placeholder = placeholder
        self.symbolName = symbolName
        self.candidates = candidates
    }
}

/// 本体と個々のプラグインの境界。
///
/// - コマンド定義は通常検索とホットキーの両方から参照される。
/// - 設定はプラグイン自身が読み、失敗時の直前正常値も自身で保持する。
/// - 本体はプラグイン固有の設定型や候補生成を知らない。
@MainActor
public protocol LauncherPlugin: AnyObject {
    var id: String { get }
    var commands: [PluginCommand] { get }

    var configurationIssues: [ConfigIssue] { get }
    func loadConfiguration()
    func startWatchingConfiguration(
        onChange: @escaping @MainActor () -> Void
    ) -> Bool
    func stopWatchingConfiguration()

    /// コマンドが作る一覧。自分のコマンドでなければ nil。
    ///
    /// 表示や設定再読込で複数回呼ばれうるため、外部コマンドなどの副作用は実行せず、
    /// 選択後に動かす `CandidateAction` として返す。
    func list(for commandID: String) -> PluginList?
}

/// 設定を持たないプラグイン向けの既定実装。
extension LauncherPlugin {
    public var configurationIssues: [ConfigIssue] { [] }
    public func loadConfiguration() {}
    public func startWatchingConfiguration(
        onChange: @escaping @MainActor () -> Void
    ) -> Bool { true }
    public func stopWatchingConfiguration() {}
}
