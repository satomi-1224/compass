import AppKit
import ApplicationServices
import ClipboardHistory
import CompassCore
import HotkeyEngine
import PluginCatalog
import PluginKit
import SearchUI

/// 不可視の常駐プロセス（requirements.md 5.3）。
///
/// メニューバーにも Dock にも出ない。`Info.plist` の `LSUIElement` と
/// `.accessory` の activation policy の両方で担保する。
///
/// **起動やリロードの成功は通知しない。** 正常時は完全に黙り、エラーだけを
/// 通知センターに出す。
@MainActor
final class CompassDelegate: NSObject, NSApplicationDelegate {

    private let log = Log.shared
    private let store: ConfigStore
    private let plugins: PluginRegistry
    private let engine = HotkeyEngine()
    private var search: SearchController?
    private var clipboard: ClipboardHistory?

    override init() {
        let directory = ConfigStore.defaultDirectory
        let plugins = PluginCatalog.makeRegistry(configDirectory: directory)
        self.plugins = plugins
        self.store = ConfigStore(directory: directory, pluginActions: plugins.commandIDs)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        // 設定は使うたびに読み直させる。リロードがそのまま反映される。
        let search = SearchController(
            config: { [weak self] in self?.store.config ?? Config() },
            issues: { [weak self] in
                guard let self else { return [] }
                return self.store.issues + self.plugins.issues
            },
            configDirectory: store.directory,
            plugins: plugins
        )
        search.start()
        self.search = search

        clipboard = ClipboardHistory(settings: { [weak self] in
            self?.store.config.clipboard ?? Config.Clipboard()
        })

        engine.onTrigger = { [weak self] binding in
            self?.perform(binding.action)
        }

        let coreIssues = store.load()
        let pluginIssues = plugins.loadConfigurations()
        if coreIssues.isEmpty, pluginIssues.isEmpty {
            log.info("設定を読み込んだ: \(store.directory.path)")
        }
        applyConfiguration()

        // 初回適用のあとに繋ぐ。load() の中で呼ばれて二重に適用されるのを避ける。
        store.onChange = { [weak self] in self?.applyConfiguration() }
        plugins.onChange = { [weak self] in
            guard let self else { return }
            self.search?.refreshVisiblePlugin()
            self.log.debug("プラグイン設定を再読み込みした")
        }

        if !store.startWatching() {
            log.warn("設定ディレクトリを監視できない: \(store.directory.path)")
        }
        if !plugins.startWatching() {
            log.warn("一部のプラグイン設定を監視できない: \(store.directory.path)/plugins")
        }

        requestAccessibilityIfNeeded()
        showWindowIfRequested()
    }

    /// ペーストを使う設定なのに権限が無ければ、許可を求める。
    ///
    /// **プロンプトを出さないとシステム設定の一覧にも現れない。** ユーザーが「+」から
    /// 手で探して追加するしかなくなる。要件 5.3 の「正常時は黙る」に反しないよう、
    /// ホットキーまたは通常検索から貼り付け機能へ到達できなければ何もしない。
    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }

        // プラグインはホットキーへ割り当てなくても通常検索から使える。設定された
        // ホットキーだけを見ると、検索経由で初めて貼り付ける人へ許可を案内できない。
        let usesPaste =
            plugins.hasAccessibilityDependentCommands
            || store.hotkeys.bindings.contains { binding in
                binding.action == .builtin(.clipboard)
            }
        guard usesPaste else { return }

        log.warn(
            "アクセシビリティ権限が無い。貼り付けを行う機能に必要"
                + "（許可するまで、選んでもクリップボードに載るだけで貼られない）")
        // `kAXTrustedCheckOptionPrompt` は C の `extern CFStringRef` で、Swift 6 からは
        // 共有可変状態として扱われて参照できない。値は変わらないのでリテラルで書く。
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// 起動直後に窓を出す開発用の入口。
    ///
    /// ```
    /// --show-search [クエリ]   検索窓
    /// --show-clipboard         クリップボード履歴
    /// --show-snippets          スニペット一覧
    /// ```
    ///
    /// ホットキーを押さずに見た目と候補の出方を確かめられる。常用のホットキーが
    /// 他のアプリと衝突している状況でも検証できる。
    private func showWindowIfRequested() {
        let arguments = CommandLine.arguments

        if arguments.contains("--show-clipboard") {
            log.info("--show-clipboard: クリップボード履歴を出す")
            toggleList(
                id: "clipboard",
                placeholder: "クリップボード履歴",
                symbolName: "list.clipboard"
            ) {
                [weak self] in
                self?.clipboard?.candidates() ?? []
            }
            return
        }

        if arguments.contains("--show-snippets") {
            log.info("--show-snippets: スニペット一覧を出す")
            _ = search?.presentPluginCommand("snippets")
            return
        }

        guard let index = arguments.firstIndex(of: "--show-search") else { return }
        log.info("--show-search: 検索窓を出す")
        search?.present(.search)

        let next = index + 1
        if arguments.indices.contains(next), !arguments[next].hasPrefix("--") {
            search?.setQuery(arguments[next])
        }
    }

    /// 読み込んだ設定を各モジュールへ渡す。
    private func applyConfiguration() {
        let failures = engine.apply(store.hotkeys)
        if !failures.isEmpty {
            // 登録できなかったキーは黙って消えると気づけない。
            Notifier.shared.report(failures)
        }
        // `enabled` や `poll_interval` が変わったら監視をやり直す。start() は
        // stop してから始めるので、繰り返し呼んでも積み上がらない。
        clipboard?.start()

        log.debug(
            "設定を適用: trigger=\(store.hotkeys.trigger.symbols)"
                + " bindings=\(engine.registeredCount)/\(store.hotkeys.bindings.count)"
                + " plugin_commands=\(plugins.commandCount)"
                + " clipboard=\(store.config.clipboard.enabled ? "on" : "off")"
        )
    }

    /// ホットキーが押されたときの振り分け。
    private func perform(_ action: Action) {
        switch action {
        case .command(let command):
            ActionRunner.run(command)
        case .plugin(let commandID):
            _ = search?.togglePluginCommand(commandID)
        case .builtin(let builtin):
            switch builtin {
            case .search:
                search?.toggle(.search)
            case .clipboard:
                toggleList(
                    id: "clipboard",
                    placeholder: "クリップボード履歴",
                    symbolName: "list.clipboard"
                ) {
                    [weak self] in
                    self?.clipboard?.candidates() ?? []
                }
            }
        }
    }

    /// 一覧を開閉する。
    ///
    /// **同じ一覧なら閉じ、違う入口なら切り替える。** 履歴を見ている最中に
    /// 別のプラグインのキーを押したら、閉じるのではなくその一覧が出てほしい。
    ///
    /// 候補は**開くときだけ**作る。閉じるときに作っても捨てるだけで、
    /// クリップボード履歴のように件数が多いと無駄になる。
    private func toggleList(
        id: String, placeholder: String, symbolName: String, candidates: () -> [Candidate]
    ) {
        guard let search else { return }
        if search.isShowing(.list(id)) {
            search.dismiss()
            return
        }
        search.present(
            .list(
                id: id,
                placeholder: placeholder,
                symbolName: symbolName,
                candidates: candidates()
            ))
    }

    /// **`Cmd+V` を解釈させるには Edit メニューが必要**（requirements.md 7.4）。
    ///
    /// AppKit はキー等価物をメインメニューで解決する。メニューが無いと keyDown は
    /// ビューまで届くのに `paste:` へ変換されない。メニューバーには出ないが、
    /// 検索窓の入力欄で編集操作を効かせるために必要。
    private func buildMenu() {
        let mainMenu = NSMenu()

        // 先頭の項目は App メニューとして扱われる。
        // **Quit にキー等価物は付けない。** 検索窓を開いている最中の Cmd+Q で
        // 常駐が落ちると、以後ホットキーが全て死ぬ。
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit compass",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - 起動

// 一覧を出すだけのオプションは窓も常駐も要らない。出して終わる。

// Spotlight を使わない走査が意図した範囲を拾えているかを確かめる。
// `--print-apps | grep Remap` で PWA が出るかを見る、といった使い方をする。
if CommandLine.arguments.contains("--print-apps") {
    let provider = AppProvider()
    // **同期版を使う。** refresh() はバックグラウンドで走るので、直後に読むと空。
    provider.start()
    for candidate in provider.candidates(matching: "", limit: .max) {
        print("\(candidate.title)\t\(candidate.subtitle ?? "")")
    }
    exit(0)
}

// `hotkeys.toml` に書けるキー名。
if CommandLine.arguments.contains("--print-keys") {
    print(KeyTable.allNames.joined(separator: "\n"))
    exit(0)
}

// `plugins/snippets.toml` の `body` に書けるプレースホルダ。
if CommandLine.arguments.contains("--print-placeholders") {
    for placeholder in PluginCatalog.snippetPlaceholders {
        print("\(placeholder.syntax)\t\(placeholder.meaning)")
    }
    exit(0)
}

// `--print-candidates <クエリ>` で検索結果を出して終わる。
//
// **窓もホットキーもアクセシビリティ権限も使わずに検索を検証できる。**
// キーワード切替（`g swift`）も含めて、実際に窓へ出るのと同じ候補が出る。
if let index = CommandLine.arguments.firstIndex(of: "--print-candidates") {
    // **クエリが無いときに黙って常駐へ落ちてはいけない。** ホットキーを登録し、
    // 権限のダイアログまで出してしまう。
    let next = index + 1
    guard CommandLine.arguments.indices.contains(next),
        !CommandLine.arguments[next].hasPrefix("--")
    else {
        FileHandle.standardError.write(
            Data("使い方: compass --print-candidates <クエリ>\n".utf8))
        exit(1)
    }

    let query = CommandLine.arguments[next]
    let directory = ConfigStore.defaultDirectory
    let plugins = PluginCatalog.makeRegistry(configDirectory: directory)
    let store = ConfigStore(directory: directory, pluginActions: plugins.commandIDs)
    store.load()
    plugins.loadConfigurations()

    let controller = SearchController(config: { store.config }, plugins: plugins)
    controller.start()
    controller.candidates(for: query) { candidates in
        for candidate in candidates {
            print("\(candidate.title)\t\(candidate.subtitle ?? "")")
        }
        exit(0)
    }

    // ファイル検索は Spotlight を待つ。結果が届くまで RunLoop を回す。
    // 返らないまま待ち続けないよう上限を置く。
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
        FileHandle.standardError.write(Data("候補が返らなかった（10 秒）\n".utf8))
        exit(1)
    }
    RunLoop.main.run()
}

let application = NSApplication.shared
// delegate は weak 参照なので、グローバルに置いて保持する。
let delegate = CompassDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
