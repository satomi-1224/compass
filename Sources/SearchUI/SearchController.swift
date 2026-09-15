import AppKit
import CompassCore
import PluginKit

/// 検索窓を出して、選ばれた候補を実行する。
///
/// クリップボード履歴とプラグイン一覧も同じ窓を使う（requirements.md 6章）。
/// 候補の供給元が違うだけで「絞り込む → 選ぶ → 実行」は同一。
@MainActor
public final class SearchController {

    /// 窓が何を出しているか。
    public enum Presentation: Sendable {
        /// 素の検索。入力に応じてアプリ・ファイル・Web を切り替える。
        case search
        /// あらかじめ用意した候補から選ぶ。
        ///
        /// - Parameter symbolName: 入力欄の左に置く SF Symbol。今どのモードかを示す。
        case list(
            id: String, placeholder: String, symbolName: String, candidates: [Candidate]
        )
        /// 登録済みプラグインのコマンドから開いた一覧。
        ///
        /// commandID を保つため、設定の再読込後も表示中の一覧だけを更新できる。
        case plugin(commandID: String, list: PluginList)

        /// どの入口か。**候補の中身は見ない。**
        ///
        /// 同じ入口のキーをもう一度押したら閉じ、違う入口なら切り替えるための判定に使う。
        public var kind: Kind {
            switch self {
            case .search: .search
            case .list(let id, _, _, _): .list(id)
            case .plugin(let commandID, _): .plugin(commandID)
            }
        }

        public enum Kind: Equatable, Sendable {
            case search
            /// 一覧は表示文言ではなく、安定した ID で区別する。
            case list(String)
            /// 本体一覧と ID が同じでも別の入口として扱う。
            case plugin(String)
        }
    }

    /// 候補が無いときに出す文言。**窓が入力欄だけに縮むと、絞り込めていないのか
    /// 探している最中なのかが区別できない。**
    enum Status {
        static let noMatch = "一致するものがない"
        static let searching = "探しています…"
        static let brokenURL = "url を組み立てられない（config.toml の {query} を確認）"
        static var tooShort: String {
            "\(FileProvider.minimumQueryLength) 文字以上で探します"
        }
    }

    /// ファイル検索を始めるまでの待ち。
    ///
    /// **1 打鍵ごとに Spotlight へ問い合わせない。** `NSMetadataQuery` は開始と停止の
    /// たびに mds へ往復し、打っている最中はそのほとんどが捨てられる。
    private static let fileSearchDelay: TimeInterval = 0.15

    private let log: Log
    private let apps: AppProvider
    private let files: FileProvider
    private let plugins: PluginRegistry
    /// 窓を開くたびに評価する。設定のリロードがそのまま反映される。
    private let config: @MainActor () -> Config
    /// 直近の設定の不備。**検索窓を開いたときに先頭へ出す。**
    private let issues: @MainActor () -> [ConfigIssue]
    /// 設定ファイルの置き場。不備の行を選んだら、そのファイルを開く。
    private let configDirectory: URL

    private var window: SearchWindow?
    private var presentation: Presentation = .search
    /// 一覧モードで絞り込む元の候補。
    private var listSource: [Candidate] = []
    /// 待たせているファイル検索。次の入力が来たら捨てる。
    private var pendingFileSearch: DispatchWorkItem?
    /// 窓を開く前に前面だったアプリ。**閉じたときにここへ戻す。**
    ///
    /// `.nonactivatingPanel` でも `makeKeyAndOrderFront` でパネルがキーウィンドウに
    /// なる。`orderOut` しただけでは元のアプリへ確実に戻らず、送った `Cmd+V` が
    /// compass 自身に届いて消えることがある（貼り先が無いため何も起きない）。
    private var previousApplication: NSRunningApplication?

    public init(
        config: @escaping @MainActor () -> Config,
        issues: @escaping @MainActor () -> [ConfigIssue] = { [] },
        configDirectory: URL = ConfigStore.defaultDirectory,
        plugins: PluginRegistry = PluginRegistry(),
        appRoots: [String] = AppProvider.defaultRoots,
        log: Log = .shared
    ) {
        self.config = config
        self.issues = issues
        self.configDirectory = configDirectory
        self.plugins = plugins
        self.log = log
        self.apps = AppProvider(roots: appRoots, log: log)
        self.files = FileProvider(log: log)

        // 走査はバックグラウンドなので、窓を開いた直後の入力は古い一覧に当たる。
        // 終わったら同じ入力で引き直す。
        //
        // **アプリを引いているときだけ。** 一覧モードやファイル検索の最中に
        // 引き直すと、関係のない走査の完了で Spotlight への問い合わせがやり直しになる。
        apps.onRefresh = { [weak self] in
            guard let self, let window = self.window, case .search = self.presentation else {
                return
            }
            let parsed = QueryParser.parse(window.query, keywords: self.config().search.keywords)
            guard parsed.mode == .apps, !parsed.query.isEmpty else { return }
            self.updateCandidates(for: window.query)
        }
    }

    /// アプリの列挙を始める。起動直後に呼ぶ。
    public func start() {
        apps.start()
    }

    /// 列挙できたアプリの数。動作確認用。
    public var appCount: Int { apps.count }

    /// 通常検索へ公開されているプラグインコマンド数。動作確認用。
    public var pluginCommandCount: Int { plugins.commandCount }

    public var isVisible: Bool { window?.isVisible == true }

    /// その入口を今出しているか。
    public func isShowing(_ kind: Presentation.Kind) -> Bool {
        isVisible && presentation.kind == kind
    }

    // MARK: - 開閉

    /// 同じ入口なら閉じ、違う入口なら切り替える。
    ///
    /// **違う入口で閉じるだけにしない。** 履歴を見ている最中に検索窓のキーを押したら
    /// 検索窓が出てほしい。閉じるだけでは、押し直す一手が毎回増える。
    public func toggle(_ presentation: Presentation) {
        if isShowing(presentation.kind) {
            dismiss()
        } else {
            present(presentation)
        }
    }

    /// プラグインコマンドを通常検索から開く。
    @discardableResult
    public func presentPluginCommand(_ commandID: String) -> Bool {
        guard let list = plugins.list(for: commandID) else {
            log.error("プラグインコマンドを解決できない: \(commandID)")
            return false
        }
        present(.plugin(commandID: commandID, list: list))
        return true
    }

    /// プラグインコマンドを直接ホットキーから開閉する。
    @discardableResult
    public func togglePluginCommand(_ commandID: String) -> Bool {
        // 同じ入口なら候補を作る前に閉じる。動的な候補の生成は、実際に開くときだけ。
        if isShowing(.plugin(commandID)) {
            dismiss()
            return true
        }
        guard let list = plugins.list(for: commandID) else {
            log.error("プラグインコマンドを解決できない: \(commandID)")
            return false
        }
        toggle(.plugin(commandID: commandID, list: list))
        return true
    }

    /// 表示中のプラグイン設定が変わったとき、入力と選択の流れを保ったまま更新する。
    public func refreshVisiblePlugin() {
        guard let window, case .plugin(let commandID, _) = presentation,
            let list = plugins.list(for: commandID)
        else { return }

        presentation = .plugin(commandID: commandID, list: list)
        listSource = list.candidates
        updateListCandidates(in: window, matching: window.query, name: list.placeholder)
    }

    /// 窓は開くたびに作り直す。設定（幅・表示件数）の変更が自然に反映される。
    public func present(_ presentation: Presentation) {
        cancelFileSearch()

        if let existing = window {
            // 開いたまま入口が切り替わった。**前の窓を必ず片付ける。**
            // 残すと画面に居座り、閉じる手立てが無くなる。
            // 貼り先（previousApplication）は開いたときのものを保つ。
            existing.detach()
            existing.dismiss()
        } else {
            // 貼り先を覚えておく。窓を出す前に取らないと自分自身になる。
            previousApplication = NSWorkspace.shared.frontmostApplication
        }

        let appearance = config().appearance
        let window = SearchWindow(
            width: appearance.width, maxVisibleRows: appearance.maxResults, log: log)

        window.onQueryChange = { [weak self] text in self?.updateCandidates(for: text) }
        window.onSubmit = { [weak self] in self?.submit() }
        window.onCancel = { [weak self] in self?.dismiss() }
        // **他のアプリへ移った場合は元のアプリを呼び戻さない。** ユーザーが今
        // クリックした相手を追い越してしまう。
        window.onResignKey = { [weak self] in self?.dismiss(restoringFocus: false) }

        self.window = window
        self.presentation = presentation

        switch presentation {
        case .search:
            listSource = []
            // Spotlight の live update が使えないので、開くたびに走査し直す
            // （バックグラウンドで走るので窓は待たされない）。
            apps.refresh()
            // 動詞は省く。何が対象かだけ示せば足りる。
            //
            // **開いた時点で設定の不備を出す。** 打ち始める前に目に入る位置が、
            // 不可視の常駐でエラーを伝えられる唯一の場所。
            window.present(
                placeholder: "アプリ・コマンド・ファイル・Web",
                symbolName: "magnifyingglass",
                candidates: issueCandidates()
            )
        case .list(_, let placeholder, let symbolName, let candidates):
            showList(
                in: window,
                placeholder: placeholder,
                symbolName: symbolName,
                candidates: candidates
            )
        case .plugin(_, let list):
            showList(
                in: window,
                placeholder: list.placeholder,
                symbolName: list.symbolName,
                candidates: list.candidates
            )
        }
    }

    private func showList(
        in window: SearchWindow,
        placeholder: String,
        symbolName: String,
        candidates: [Candidate]
    ) {
        listSource = candidates
        window.present(
            placeholder: placeholder, symbolName: symbolName, candidates: candidates)
        // 空のまま開いたら、絞り込む前にそう言う。窓が入力欄だけに縮むと
        // 「開けていない」のか「中身が無い」のか分からない。
        if candidates.isEmpty {
            window.setCandidates(
                [], matching: "",
                status: Self.listStatus(found: [], source: [], name: placeholder))
        }
        log.debug("一覧を開いた: \(placeholder) \(candidates.count) 件")
    }

    /// - Parameter restoringFocus: 開く前のアプリへ戻すか。
    ///   **貼り付けのときだけ true にする。** 他のアプリへ移って閉じた場合や、
    ///   アプリ・URL を開く場合に戻すと、来てほしい相手を追い越してしまう。
    public func dismiss(restoringFocus: Bool = true) {
        cancelFileSearch()
        files.cancel()
        window?.dismiss()
        window = nil
        listSource = []

        guard restoringFocus else {
            previousApplication = nil
            return
        }
        restorePreviousApplication()
    }

    /// 開く前に前面だったアプリへ戻す。
    ///
    /// **これをしないとペーストが飛ばない。** パネルがキー入力を握っていた状態から
    /// 閉じただけでは、キーウィンドウが元のアプリへ戻るとは限らない。
    private func restorePreviousApplication() {
        guard let previous = previousApplication else { return }
        previousApplication = nil
        // 自分自身なら戻す相手がいない。
        guard previous.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        // `.accessory` のアプリからの activate は macOS の判断で断られることがある。
        // 断られたら貼り先が変わらないので、手がかりを残す。
        if !previous.activate() {
            log.debug("前面へ戻せなかった: \(previous.bundleIdentifier ?? "不明")")
        }
    }

    /// 入力を流し込んで候補を更新する。ホットキーを押さずに挙動を確かめるための
    /// 開発用の入口（`--show-search`）。
    public func setQuery(_ text: String) {
        window?.setQuery(text)
        updateCandidates(for: text)
    }

    // MARK: - 候補

    private func updateCandidates(for text: String) {
        guard let window else { return }
        cancelFileSearch()

        switch presentation {
        case .list(_, let placeholder, _, _):
            updateListCandidates(in: window, matching: text, name: placeholder)

        case .plugin(_, let list):
            updateListCandidates(in: window, matching: text, name: list.placeholder)

        case .search:
            let current = config()
            let parsed = QueryParser.parse(text, keywords: current.search.keywords)

            guard !parsed.query.isEmpty else {
                // 入力を促す。空で全アプリを並べても選べない。
                //
                // **設定に不備があるときだけは出す。** 不可視の常駐なので、通知が
                // 届かない環境ではここが唯一エラーに気づける場所になる。
                files.cancel()
                window.setCandidates(issueCandidates(), matching: "", status: nil)
                return
            }

            switch parsed.mode {
            case .apps:
                files.cancel()
                let found = primaryCandidates(
                    matching: parsed.query, limit: current.appearance.maxResults)
                show(found, matching: parsed.query)

            case .web(let keyword):
                files.cancel()
                let found = Self.webCandidates(for: keyword, query: parsed.query)
                // Web は入力そのものが title なので、全部が当たって太く見える。強調しない。
                window.setCandidates(
                    found, matching: "", status: found.isEmpty ? Status.brokenURL : nil)

            case .files:
                scheduleFileSearch(parsed.query, input: text, config: current)
            }
        }
    }

    private func updateListCandidates(
        in window: SearchWindow, matching text: String, name: String
    ) {
        let limit = config().appearance.maxResults
        let found = FuzzyMatcher.filter(listSource, query: text, limit: limit)
        window.setCandidates(
            found, matching: text,
            status: Self.listStatus(found: found, source: listSource, name: name))
    }

    /// アプリとプラグインコマンドを一度に順位付けする。
    ///
    /// 別々に上限を掛けてから結合すると、後から足した側が常に不利になる。同じ候補集合へ
    /// fuzzy マッチを 1 回だけ適用し、種類に依存しない順位と件数上限にする。
    private func primaryCandidates(matching query: String, limit: Int) -> [Candidate] {
        FuzzyMatcher.filter(
            apps.allCandidates + plugins.commandCandidates,
            query: query,
            limit: limit
        )
    }

    /// 設定の不備を候補にする。選ぶと該当のファイルが開く。
    ///
    /// **通知が唯一の手段だと取りこぼす。** bundle identifier が通知不可の状態に
    /// なっていると `requestAuthorization` は黙って失敗し、ログを見に行く習慣が
    /// なければ「設定を直したのに効かない」で止まってしまう。
    private func issueCandidates() -> [Candidate] {
        issues().enumerated().map { index, issue in
            let path = configDirectory.appendingPathComponent(issue.file.fileName).path
            return Candidate(
                id: "issue:\(index)",
                title: issue.detail,
                subtitle: "\(issue.file.fileName) — 選ぶと開く",
                icon: .symbol("exclamationmark.triangle"),
                action: .open(path: path)
            )
        }
    }

    /// 一覧モードで候補が無いときの文言。
    ///
    /// **「空」と「絞り込んで 0 件」は別物。** 履歴が空なのに「一致するものがない」と
    /// 出ると、打った覚えのない絞り込みが効いているように見える。
    private static func listStatus(
        found: [Candidate], source: [Candidate], name: String
    ) -> String? {
        guard found.isEmpty else { return nil }
        return source.isEmpty ? "\(name)は空" : Status.noMatch
    }

    private func show(_ found: [Candidate], matching query: String) {
        window?.setCandidates(
            found, matching: query, status: found.isEmpty ? Status.noMatch : nil)
    }

    /// ファイル検索を待たせてから始める。
    ///
    /// **今出ている候補は消さない。** 1 打鍵ごとに一覧が空になって戻るのは、
    /// 探せていないように見えるうえに目が疲れる。まだ何も出ていないときだけ
    /// 「探しています…」を出す。
    private func scheduleFileSearch(_ query: String, input: String, config: Config) {
        guard let window else { return }

        let effective = FileProvider.effectiveQuery(for: query)
        guard FileProvider.isSearchable(effective) else {
            files.cancel()
            window.setCandidates([], matching: query, status: Status.tooShort)
            return
        }
        if !window.hasCandidates {
            window.setCandidates([], matching: query, status: Status.searching)
        }

        let limit = config.appearance.maxResults
        let scopes = config.search.files.scopes
        let exclude = config.search.files.exclude
        let fileLimit = config.search.files.maxResults

        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window?.query == input else { return }
                self.files.search(query, scopes: scopes, exclude: exclude, limit: fileLimit) {
                    found in
                    // 届くまでに入力が変わっているかもしれない。
                    guard let window = self.window, window.query == input else { return }
                    let limited = Array(found.prefix(limit))
                    self.log.debug("候補: \"\(input)\" → \(limited.count) 件")
                    self.show(limited, matching: query)
                }
            }
        }
        pendingFileSearch = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fileSearchDelay, execute: item)
    }

    private func cancelFileSearch() {
        pendingFileSearch?.cancel()
        pendingFileSearch = nil
    }

    private static func webCandidates(
        for keyword: Config.Keyword, query: String
    ) -> [Candidate] {
        guard let url = keyword.resolvedURL(for: query) else { return [] }
        return [
            Candidate(
                id: "web:\(keyword.prefix)",
                title: query,
                // **percent encode したものは出さない。** 日本語で検索したときに
                // `%E6%A4%9C%E7%B4%A2` が並んで、どこへ行くのか読めなくなる。
                subtitle: keyword.displayURL(for: query),
                icon: .symbol("globe"),
                action: .openURL(url)
            )
        ]
    }

    /// クエリに対する検索候補。
    ///
    /// **窓を介さずに使える。** `--print-candidates` から呼んで、ホットキーも
    /// 権限も要らずに検索の挙動を確かめられるようにしてある。**待たせずに引く**ので、
    /// 窓の側の debounce には影響されない。
    ///
    /// ファイル検索は Spotlight を待つため、completion は非同期に呼ばれることがある。
    public func candidates(
        for text: String, completion: @escaping @MainActor ([Candidate]) -> Void
    ) {
        let current = config()
        let limit = current.appearance.maxResults
        let parsed = QueryParser.parse(text, keywords: current.search.keywords)

        // 走っているファイル検索は捨てる。古い結果が後から届くと一覧が入れ替わる。
        files.cancel()

        guard !parsed.query.isEmpty else {
            completion([])
            return
        }

        switch parsed.mode {
        case .apps:
            completion(primaryCandidates(matching: parsed.query, limit: limit))

        case .files:
            files.search(
                parsed.query,
                scopes: current.search.files.scopes,
                exclude: current.search.files.exclude,
                limit: current.search.files.maxResults
            ) { found in
                completion(Array(found.prefix(limit)))
            }

        case .web(let keyword):
            completion(Self.webCandidates(for: keyword, query: parsed.query))
        }
    }

    // MARK: - 実行

    /// 窓を閉じてフォーカスが元のアプリへ戻るまでの待ち時間。
    ///
    /// `activate()` は非同期に効くので、少し余裕を持たせる。短すぎると
    /// 切り替わる前に `Cmd+V` が飛んで取りこぼす。
    private static let focusReturnDelay: TimeInterval = 0.15

    private func submit() {
        guard let candidate = window?.selected else { return }
        // **中身をログへ出さない。** クリップボード履歴の title はコピーした
        // テキストそのもの。launchd 経由だと永続ファイルに平文で残る
        // （貼るときに transient を立てて履歴から守っているのと矛盾する）。
        log.debug("実行: \(candidate.id)")

        let log = self.log
        switch candidate.action {
        case .paste(let text):
            log.debug("貼り付け: \(text.count) 文字")
            dismiss()
            pasteAfterFocusReturns { ActionRunner.paste(text, log: log) }

        case .pasteCommandOutput(let command):
            // **コマンドの実行も同じ遅延に載せる。** `echo` や
            // `git branch --show-current` は数ミリ秒で終わるので、出力を待つだけでは
            // まだ閉じ切っていない自分の入力欄に貼られてしまう。
            dismiss()
            pasteAfterFocusReturns { ActionRunner.pasteOutput(of: command, log: log) }

        case .open, .openURL:
            // **開く相手が前面に来るべきなので、元のアプリへ戻さない。**
            // `activate()` は非同期に効くため、戻してから開くと起動したアプリが
            // 元のアプリの後ろに隠れる。
            dismiss(restoringFocus: false)
            ActionRunner.run(candidate.action, log: log)

        case .invokePluginCommand(let commandID):
            // 元のアプリは貼り先として保持したまま、同じ窓をプラグイン一覧へ切り替える。
            _ = presentPluginCommand(commandID)
        }
    }

    /// **閉じてフォーカスが戻るのを待ってから貼る。** 即座に送ると、まだ自分が
    /// キーウィンドウのままで入力欄に貼られる。
    private func pasteAfterFocusReturns(_ body: @escaping @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusReturnDelay, execute: body)
    }
}
