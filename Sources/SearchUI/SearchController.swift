import AppKit
import CompassCore

/// 検索窓を出して、選ばれた候補を実行する。
///
/// クリップボード履歴とスニペット一覧も同じ窓を使う（requirements.md 6章）。
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
        case list(placeholder: String, symbolName: String, candidates: [Candidate])
    }

    private let log: Log
    private let apps: AppProvider
    private let files: FileProvider
    /// 窓を開くたびに評価する。設定のリロードがそのまま反映される。
    private let config: @MainActor () -> Config

    private var window: SearchWindow?
    private var presentation: Presentation = .search
    /// 一覧モードで絞り込む元の候補。
    private var listSource: [Candidate] = []

    public init(config: @escaping @MainActor () -> Config, log: Log = .shared) {
        self.config = config
        self.log = log
        self.apps = AppProvider(log: log)
        self.files = FileProvider(log: log)
    }

    /// アプリの列挙を始める。起動直後に呼ぶ。
    public func start() {
        apps.start()
    }

    /// 列挙できたアプリの数。動作確認用。
    public var appCount: Int { apps.count }

    public var isVisible: Bool { window?.isVisible == true }

    // MARK: - 開閉

    /// 開いていれば閉じ、閉じていれば開く。同じホットキーで往復できる。
    public func toggle(_ presentation: Presentation) {
        if isVisible {
            dismiss()
        } else {
            present(presentation)
        }
    }

    /// 窓は開くたびに作り直す。設定（幅・表示件数）の変更が自然に反映される。
    public func present(_ presentation: Presentation) {
        let appearance = config().appearance
        let window = SearchWindow(
            width: appearance.width, maxVisibleRows: appearance.maxResults)

        window.onQueryChange = { [weak self] text in self?.updateCandidates(for: text) }
        window.onSubmit = { [weak self] in self?.submit() }
        window.onCancel = { [weak self] in self?.dismiss() }

        self.window = window
        self.presentation = presentation

        switch presentation {
        case .search:
            listSource = []
            // Spotlight の live update が使えないので、開くたびに走査し直す。
            apps.refresh()
            // 動詞は省く。何が対象かだけ示せば足りる。
            window.present(
                placeholder: "アプリ・ファイル・Web",
                symbolName: "magnifyingglass",
                candidates: []
            )
        case .list(let placeholder, let symbolName, let candidates):
            listSource = candidates
            window.present(
                placeholder: placeholder, symbolName: symbolName, candidates: candidates)
            log.debug("一覧を開いた: \(placeholder) \(candidates.count) 件")
        }
    }

    public func dismiss() {
        files.cancel()
        window?.dismiss()
        window = nil
        listSource = []
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

        switch presentation {
        case .list:
            let limit = config().appearance.maxResults
            window.setCandidates(FuzzyMatcher.filter(listSource, query: text, limit: limit))

        case .search:
            candidates(for: text) { [weak self] found in
                guard let self else { return }
                // 届くまでに入力が変わっているかもしれない。
                guard let window = self.window, window.query == text else { return }
                self.log.debug("候補: \"\(text)\" → \(found.count) 件")
                window.setCandidates(found)
            }
        }
    }

    /// クエリに対する検索候補。
    ///
    /// **窓を介さずに使える。** `--print-candidates` から呼んで、ホットキーも
    /// 権限も要らずに検索の挙動を確かめられるようにしてある。
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
            // 入力を促す。空で全アプリを並べても選べない。
            completion([])
            return
        }

        switch parsed.mode {
        case .apps:
            completion(apps.candidates(matching: parsed.query, limit: limit))

        case .files:
            files.search(
                parsed.query,
                scopes: current.search.files.scopes,
                limit: current.search.files.maxResults
            ) { found in
                completion(Array(found.prefix(limit)))
            }

        case .web(let keyword):
            guard let url = keyword.resolvedURL(for: parsed.query) else {
                completion([])
                return
            }
            completion([
                Candidate(
                    id: "web:\(keyword.prefix)",
                    title: parsed.query,
                    subtitle: url.absoluteString,
                    action: .openURL(url)
                )
            ])
        }
    }

    // MARK: - 実行

    /// 窓を閉じてフォーカスが元のアプリへ戻るまでの待ち時間。
    private static let focusReturnDelay: TimeInterval = 0.1

    private func submit() {
        guard let candidate = window?.selected else { return }
        dismiss()

        let log = self.log
        switch candidate.action {
        case .paste(let text):
            pasteAfterFocusReturns { ActionRunner.paste(text, log: log) }

        case .pasteCommandOutput(let command):
            // **コマンドの実行も同じ遅延に載せる。** `echo` や
            // `git branch --show-current` は数ミリ秒で終わるので、出力を待つだけでは
            // まだ閉じ切っていない自分の入力欄に貼られてしまう。
            pasteAfterFocusReturns { ActionRunner.pasteOutput(of: command, log: log) }

        case .open, .openURL:
            ActionRunner.run(candidate.action, log: log)
        }
    }

    /// **閉じてフォーカスが戻るのを待ってから貼る。** 即座に送ると、まだ自分が
    /// キーウィンドウのままで入力欄に貼られる。
    private func pasteAfterFocusReturns(_ body: @escaping @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusReturnDelay, execute: body)
    }
}
