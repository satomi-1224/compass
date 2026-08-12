import AppKit
import CompassCore

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

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
    }

    /// 読み込んだ設定を各モジュールへ渡す。
    private func applyConfiguration() {
        // Phase 2 でホットキーの登録・再登録をここに繋ぐ。
        log.debug(
            "設定を適用: trigger=\(store.hotkeys.trigger.symbols)"
                + " bindings=\(store.hotkeys.bindings.count)"
                + " snippets=\(store.snippets.count)"
                + " clipboard=\(store.config.clipboard.enabled ? "on" : "off")"
        )
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

let application = NSApplication.shared
// delegate は weak 参照なので、グローバルに置いて保持する。
let delegate = CompassDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
