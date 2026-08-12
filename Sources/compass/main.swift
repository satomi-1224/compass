import AppKit
import CompassCore
import HotkeyEngine
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
    private let store = ConfigStore()
    private let engine = HotkeyEngine()
    private var search: SearchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        // 設定は窓を開くたびに読み直させる。リロードがそのまま反映される。
        let search = SearchController(config: { [weak self] in self?.store.config ?? Config() })
        search.start()
        self.search = search

        engine.onTrigger = { [weak self] binding in
            self?.perform(binding.action)
        }

        let issues = store.load()
        if issues.isEmpty {
            log.info("設定を読み込んだ: \(store.directory.path)")
        }
        applyConfiguration()

        // 初回適用のあとに繋ぐ。load() の中で呼ばれて二重に適用されるのを避ける。
        store.onChange = { [weak self] in self?.applyConfiguration() }

        if !store.startWatching() {
            log.warn("設定ディレクトリを監視できない: \(store.directory.path)")
        }

        showSearchIfRequested()
    }

    /// `--show-search [クエリ]` で起動直後に検索窓を出す。
    ///
    /// ホットキーを押さずに見た目と候補の出方を確かめるための開発用の入口。
    /// 常用のホットキーが他のアプリと衝突している状況でも検証できる。
    private func showSearchIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--show-search") else { return }

        log.info("--show-search: 起動直後に検索窓を出す")
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
        log.debug(
            "設定を適用: trigger=\(store.hotkeys.trigger.symbols)"
                + " bindings=\(engine.registeredCount)/\(store.hotkeys.bindings.count)"
                + " snippets=\(store.snippets.count)"
                + " clipboard=\(store.config.clipboard.enabled ? "on" : "off")"
        )
    }

    /// ホットキーが押されたときの振り分け。
    private func perform(_ action: Action) {
        switch action {
        case .command(let command):
            ActionRunner.run(command)
        case .builtin(let builtin):
            switch builtin {
            case .search:
                search?.toggle(.search)
            case .clipboard:
                // Phase 4 で繋ぐ。
                log.info("クリップボード履歴は未実装")
            case .snippets:
                // Phase 5 で繋ぐ。
                log.info("スニペット一覧は未実装")
            }
        }
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

// `--print-apps` は窓も常駐も要らない。列挙して終わる。
//
// Spotlight を使わない走査が意図した範囲を拾えているかを確かめるための入口。
// `--print-apps | grep Claude` で PWA が出るかを見る、といった使い方をする。
if CommandLine.arguments.contains("--print-apps") {
    let provider = AppProvider()
    provider.refresh()
    for candidate in provider.candidates(matching: "", limit: .max) {
        print("\(candidate.title)\t\(candidate.subtitle ?? "")")
    }
    exit(0)
}

let application = NSApplication.shared
// delegate は weak 参照なので、グローバルに置いて保持する。
let delegate = CompassDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
