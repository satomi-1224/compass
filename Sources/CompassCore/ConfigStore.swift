import Foundation

/// 本体の 2 つの設定ファイルを読んで保持する。
///
/// **解釈に失敗したファイルは直前の正常な内容を保ったまま動き続ける**
/// （requirements.md 5.4）。設定を壊してもランチャーが死なないことを優先する。
///
/// ファイルが無いのはエラーではなく「空」として扱い、既定値に戻す。
/// プラグイン設定は各プラグインが `plugins/` 以下から読む。
@MainActor
public final class ConfigStore {

    public private(set) var config = Config()
    public private(set) var hotkeys = Hotkeys.fallback

    /// 直近の読み込みで見つかった不備。**直るまで残る。**
    ///
    /// 通知は環境によっては届かない（bundle identifier が通知不可の状態に
    /// なっていると `requestAuthorization` が黙って失敗する）。不可視の常駐で
    /// エラーに気づく手段が消えないよう、検索窓からも読めるようにしておく。
    public private(set) var issues: [ConfigIssue] = []

    /// 読み直して**内容が変わったとき**だけ呼ばれる。
    /// 変わっていなければ呼ばない（ホットキーの無用な再登録を避ける）。
    public var onChange: (@MainActor () -> Void)?

    public let directory: URL

    private let reporter: any IssueReporting
    private let log: Log
    private let pluginActions: Set<String>
    private var watcher: ConfigWatcher?

    public init(
        directory: URL = ConfigStore.defaultDirectory,
        pluginActions: Set<String> = [],
        reporter: any IssueReporting = Notifier.shared,
        log: Log = .shared
    ) {
        self.directory = directory
        self.pluginActions = pluginActions
        self.reporter = reporter
        self.log = log
    }

    /// `~/.config/compass/`。`XDG_CONFIG_HOME` を尊重する。
    ///
    /// 環境変数を読むだけで状態を持たないため nonisolated。init のデフォルト引数から
    /// 参照できるようにしておく。
    public nonisolated static var defaultDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        if let base = environment["XDG_CONFIG_HOME"], !base.isEmpty {
            return URL(fileURLWithPath: base, isDirectory: true)
                .appendingPathComponent("compass", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/compass", isDirectory: true)
    }

    // MARK: - 読み込み

    /// 2 ファイルを読む。**投げない。**
    ///
    /// 成功したファイルだけが差し替わる。失敗したファイルは直前の内容を保ち、
    /// 理由を通知する。
    ///
    /// - Returns: 見つかった不備。テストと起動時のログ用。
    @discardableResult
    public func load() -> [ConfigIssue] {
        var issues: [ConfigIssue] = []

        // **短絡評価させない。** `a || b` の形だと後続の読み込みが飛ぶ。
        let configChanged = loadConfig(&issues)
        let hotkeysChanged = loadHotkeys(&issues)

        self.issues = issues
        if !issues.isEmpty {
            reporter.report(issues)
        }
        if configChanged || hotkeysChanged {
            onChange?()
        }
        return issues
    }

    private func loadConfig(_ issues: inout [ConfigIssue]) -> Bool {
        switch read(.config) {
        case .missing:
            return replace(&config, with: Config())
        case .text(let text):
            do {
                return replace(&config, with: try Config.parse(text))
            } catch {
                issues.append(contentsOf: Self.issues(from: error, file: .config))
                return false
            }
        case .unreadable(let detail):
            issues.append(ConfigIssue(file: .config, detail: detail))
            return false
        }
    }

    private func loadHotkeys(_ issues: inout [ConfigIssue]) -> Bool {
        switch read(.hotkeys) {
        case .missing:
            return replace(&hotkeys, with: .fallback)
        case .text(let text):
            do {
                return replace(
                    &hotkeys, with: try Hotkeys.parse(text, pluginActions: pluginActions))
            } catch {
                issues.append(contentsOf: Self.issues(from: error, file: .hotkeys))
                return false
            }
        case .unreadable(let detail):
            issues.append(ConfigIssue(file: .hotkeys, detail: detail))
            return false
        }
    }

    // MARK: - 監視

    /// 変更を検知して自動で読み直す（requirements.md 5.2）。
    ///
    /// - Returns: 監視を張れたか。設定ディレクトリが無ければ張れない。
    @discardableResult
    public func startWatching() -> Bool {
        guard watcher == nil else { return true }
        let watcher = ConfigWatcher(
            directory: directory.path,
            fileNames: ConfigFile.coreFiles.map(\.fileName),
            log: log
        )
        watcher.onChange = { [weak self] in
            guard let self else { return }
            self.log.debug("設定の変更を検知した。読み直す")
            self.load()
        }
        guard watcher.start() else {
            // **失敗した watcher を残さない。** 残すと以後 guard に弾かれて、
            // 何も監視していないまま「張れている」と答え続ける。
            watcher.stop()
            return false
        }
        self.watcher = watcher
        return true
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    // MARK: - 補助

    private enum FileContent {
        case missing
        case text(String)
        case unreadable(String)
    }

    private func read(_ file: ConfigFile) -> FileContent {
        let url = directory.appendingPathComponent(file.fileName)
        // シンボリックリンクは追う。リンク切れは「無い」として扱う。
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            return .text(try String(contentsOf: url, encoding: .utf8))
        } catch {
            return .unreadable("読み込めない: \(error.localizedDescription)")
        }
    }

    /// 変わっていれば差し替えて true を返す。
    private func replace<T: Equatable>(_ current: inout T, with new: T) -> Bool {
        guard current != new else { return false }
        current = new
        return true
    }

    private static func issues(from error: Error, file: ConfigFile) -> [ConfigIssue] {
        if let issues = error as? ConfigIssues { return issues.items }
        return [ConfigIssue(file: file, detail: "\(error)")]
    }
}
