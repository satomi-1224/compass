// Phase 0: アクセシビリティ権限が .app の入れ替えをまたいで保持されるかを検証する最小アプリ。
//
// 検証したいのは「リビルド → 再配置 → 再起動を経ても、権限を再付与せずに
// キーストローク送出が成功するか」の一点。そのため
//
//   1. TCC が識別に使う情報（実行パス・realpath・cdhash・designated requirement）を記録し
//   2. CGEvent で自分自身のテキストフィールドに Cmd+V を送って実際に届くかを判定し
//   3. 結果を追記式のログに残してリビルド前後を比較できるようにする
//
// 自分のフィールドに送るのは、他アプリへの副作用なしに HID レベルの送出を試せるため。
// 送出経路（cghidEventTap）はシステム全体を通るので、権限がなければ届かない。
//
// 「届かなかった」の原因は権限だけではないため、切り分けの材料も併せて記録する
// （secure input、キーイベントの観測、フォーカスの所在）。

import AppKit
import ApplicationServices
import Carbon
import Security

// MARK: - 定数

/// `Cmd+V` の V。`kVK_ANSI_V` と同値を、値で持つ。
private let keyCodeV: CGKeyCode = 9

private let logFileName = "compass-phase0.log"

// MARK: - 収集した事実

/// コード署名から読める識別情報。TCC はこれでアプリの同一性を判断する。
struct SigningInfo {
    var identifier = "(unavailable)"
    var team = "(unavailable)"
    var cdHash = "(unavailable)"
    /// TCC が「同じアプリか」を判定する条件式。ここに `cdhash H"..."` が出るなら
    /// 内容を変えた時点で別アプリ扱いになり権限が外れる。証明書で固定されていれば
    /// `certificate leaf = H"..."` の形になり、内容が変わっても同一と見なされる。
    var designatedRequirement = "(unavailable)"
}

/// 送出が届かなかったときに、権限以外の原因を切り分けるための状態。
struct Diagnostics {
    var secureInputEnabled = false
    var appActive = false
    var firstResponder = "(none)"
    /// 送出した `Cmd+V` を自分のイベントストリームで観測できたか。
    /// true なのにペーストされていなければ、送出ではなく受け側の読み取りの問題。
    var keyDownObserved = false
}

/// TCC がアプリを識別する材料と、テストの結果。
struct Report {
    var timestamp: String
    var bundlePath: String
    var bundleIdentifier: String
    var executablePath: String
    /// シンボリックリンクを解いた実体のパス。nix store へリンクで配置すると
    /// ここが store のパスを指す。TCC がどちらを見るかの判断材料になる。
    var resolvedExecutablePath: String
    var executableInode: String
    var signing: SigningInfo
    var axTrusted: Bool
    var diagnostics: Diagnostics
    var pasteOutcome: String

    func formatted() -> String {
        let rows: [(String, String)] = [
            ("time", timestamp),
            ("bundle.path", bundlePath),
            ("bundle.id", bundleIdentifier),
            ("executable", executablePath),
            ("executable.resolved", resolvedExecutablePath),
            ("executable.inode", executableInode),
            ("signing.identifier", signing.identifier),
            ("signing.team", signing.team),
            ("signing.cdhash", signing.cdHash),
            ("signing.designated", signing.designatedRequirement),
            ("ax.trusted", axTrusted ? "true" : "false"),
            (
                "secure.input",
                diagnostics.secureInputEnabled
                    ? "true（有効な間は CGEvent のキー送出が届かない）"
                    : "false"
            ),
            ("app.active", diagnostics.appActive ? "true" : "false"),
            ("first.responder", diagnostics.firstResponder),
            ("keydown.observed", diagnostics.keyDownObserved ? "true" : "false"),
            ("paste.result", pasteOutcome),
        ]
        let width = rows.map(\.0.count).max() ?? 0
        return rows
            .map { "\($0.0.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.1)" }
            .joined(separator: "\n")
    }
}

// MARK: - 事実の収集

enum Probe {
    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    static func executableInode(at path: String) -> String {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let number = attributes[.systemFileNumber] as? NSNumber
        else { return "(unavailable)" }
        return number.stringValue
    }

    /// 自プロセスの署名情報を読む。
    static func signing() -> SigningInfo {
        var result = SigningInfo()

        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return result
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else {
            return result
        }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        if SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
           let dictionary = info as NSDictionary? {
            result.identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
                ?? "(unsigned)"
            result.team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String ?? "(none)"
            result.cdHash = (dictionary[kSecCodeInfoUnique as String] as? Data)
                .map { $0.map { String(format: "%02x", $0) }.joined() } ?? "(none)"
        }

        var requirement: SecRequirement?
        if SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(), &requirement) == errSecSuccess,
           let requirement {
            var text: CFString?
            if SecRequirementCopyString(requirement, SecCSFlags(), &text) == errSecSuccess,
               let text {
                result.designatedRequirement = text as String
            }
        }

        return result
    }
}

// MARK: - ログ

enum Log {
    static var url: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent(logFileName)
    }

    /// 追記でしか書かない。リビルド前後の履歴が残ることが検証の value そのもの。
    static func append(_ text: String) {
        let entry = "==== run ====\n\(text)\n\n"
        let data = Data(entry.utf8)

        // **既にあるファイルを上書きしない。** `write(to:)` は追記ではなく truncate
        // なので、開けない理由が「まだ無い」以外（読み取り専用、ロック）のときに
        // 積み上げた履歴を消してしまう。
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? data.write(to: url)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            NSLog("compass-phase0: ログを開けなかった: \(url.path)")
            return
        }
        defer { try? handle.close() }
        // 書き込みに失敗しても検証は続行する。判定はウィンドウ側にも出る。
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            NSLog("compass-phase0: ログ追記に失敗した: \(error)")
        }
    }

    static func read() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

// MARK: - キーストローク送出

enum Keystroke {
    /// `Cmd+V` を HID レベルで送出する。権限がなければ黙って無視されるため、
    /// 成否は送出の戻り値ではなくペースト先の中身で判定する。
    static func commandV() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: - アプリ

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var verdictLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var pasteTarget: NSTextField!
    private var logView: NSTextView!
    private var retryButton: NSButton!

    private var keyMonitor: Any?
    private var keyDownObserved = false
    /// 検証のために書き換える前のクリップボード。判定が済んだら戻す。
    private var savedClipboard: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        observeKeyEvents()
        NSApp.activate()
        runTest()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 送出した `Cmd+V` が自分のイベントストリームに現れるかを見る。
    /// 「送出できていない」と「送出できたが読み取れていない」を分けるため。
    private func observeKeyEvents() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(keyCodeV), event.modifierFlags.contains(.command) {
                self?.keyDownObserved = true
            }
            return event
        }
    }

    // MARK: テスト本体

    private func runTest() {
        retryButton.isEnabled = false
        pasteTarget.stringValue = ""
        keyDownObserved = false
        setVerdict("計測中…", color: .secondaryLabelColor)

        guard AXIsProcessTrusted() else {
            finish(trusted: false, outcome: "SKIPPED (no accessibility permission)")
            requestPermission()
            return
        }

        // マーカーは実行ごとに変える。前回の残りが入っていても誤判定しない。
        let marker = "COMPASS_PHASE0_\(UInt32.random(in: 0..<0xFFFF_FFFF))"
        let pasteboard = NSPasteboard.general
        // **元の内容を控えておく。** README の手順では何度も実行するので、
        // そのたびにユーザーのクリップボードを潰すのは行儀が悪い。
        savedClipboard = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(marker, forType: .string)

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(pasteTarget)

        // 送出前にフォーカスの確定を待ち、送出後にテキストの反映を待つ。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            Keystroke.commandV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                // 編集中の値は field editor が持っている。`stringValue` は
                // 編集が確定するまで古い値を返すことがあるため、先に editor を見る。
                let pasted = self.pasteTarget.currentEditor()?.string
                    ?? self.pasteTarget.stringValue
                let outcome = pasted == marker
                    ? "PASS (marker pasted)"
                    : "FAIL (expected \(marker), got \(pasted.isEmpty ? "empty" : pasted))"
                self.finish(trusted: true, outcome: outcome)
            }
        }
    }

    private func finish(trusted: Bool, outcome: String) {
        restoreClipboard()

        let bundle = Bundle.main
        let executablePath = bundle.executablePath ?? "(unavailable)"

        let diagnostics = Diagnostics(
            secureInputEnabled: IsSecureEventInputEnabled(),
            appActive: NSApp.isActive,
            firstResponder: window.firstResponder
                .map { String(describing: type(of: $0)) } ?? "(none)",
            keyDownObserved: keyDownObserved
        )

        let report = Report(
            timestamp: Probe.timestamp(),
            bundlePath: bundle.bundlePath,
            bundleIdentifier: bundle.bundleIdentifier ?? "(none)",
            executablePath: executablePath,
            resolvedExecutablePath: URL(fileURLWithPath: executablePath)
                .resolvingSymlinksInPath().path,
            executableInode: Probe.executableInode(at: executablePath),
            signing: Probe.signing(),
            axTrusted: trusted,
            diagnostics: diagnostics,
            pasteOutcome: outcome
        )

        Log.append(report.formatted())
        render(report)
        retryButton.isEnabled = true
    }

    private func render(_ report: Report) {
        if report.pasteOutcome.hasPrefix("PASS") {
            setVerdict("PASS", color: .systemGreen)
        } else if !report.axTrusted {
            setVerdict("権限なし", color: .systemOrange)
        } else if report.diagnostics.secureInputEnabled {
            setVerdict("FAIL — secure input", color: .systemOrange)
        } else {
            setVerdict("FAIL", color: .systemRed)
        }
        detailLabel.stringValue = report.formatted()
        logView.string = Log.read()
        logView.scrollToEndOfDocument(nil)
    }

    private func setVerdict(_ text: String, color: NSColor) {
        verdictLabel.stringValue = text
        verdictLabel.textColor = color
    }

    /// 検証で書き換えたクリップボードを元に戻す。判定が済んだあとに呼ぶ。
    private func restoreClipboard() {
        guard let saved = savedClipboard else { return }
        savedClipboard = nil
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(saved, forType: .string)
    }

    private func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: UI

    /// **Cmd+V を解釈させるには Edit メニューが必要。**
    ///
    /// AppKit はキー等価物をメインメニューで解決するため、メニューが無いと
    /// `Cmd+V` の keyDown はビューまで届くのに `paste:` へ変換されず、
    /// 何も起きない（この検証で実測した）。compass 本体の検索窓も
    /// `LSUIElement` でメニューバーを出さないが、`NSApp.mainMenu` の設定自体は
    /// 必要になる。
    private func buildMenu() {
        let mainMenu = NSMenu()

        // 先頭の項目は App メニューとして扱われる。Cmd+Q を効かせるために置く。
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"
        )
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "compass Phase 0 — accessibility permission check"
        window.center()

        verdictLabel = NSTextField(labelWithString: "—")
        verdictLabel.font = .systemFont(ofSize: 34, weight: .bold)

        pasteTarget = NSTextField(string: "")
        pasteTarget.placeholderString = "ここに Cmd+V が届けば送出成功"
        pasteTarget.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        detailLabel = NSTextField(labelWithString: "")
        detailLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailLabel.lineBreakMode = .byCharWrapping
        detailLabel.maximumNumberOfLines = 0

        retryButton = NSButton(title: "再テスト", target: self, action: #selector(retry))
        let settingsButton = NSButton(
            title: "プライバシー設定を開く", target: self, action: #selector(openSettings)
        )
        let revealButton = NSButton(
            title: "ログを表示", target: self, action: #selector(revealLog)
        )

        logView = NSTextView()
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = logView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let buttons = NSStackView(views: [retryButton, settingsButton, revealButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        let stack = NSStackView(views: [
            verdictLabel, pasteTarget, detailLabel, buttons, scroll,
        ])
        stack.orientation = .vertical
        // .width で子を stack の幅に揃える。個別に幅制約を張ると、折り返し幅の
        // 決まらないラベルがウィンドウを横に押し広げる。
        stack.alignment = .width
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        window.contentView = container
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])

        window.makeKeyAndOrderFront(nil)
    }

    @objc private func retry() {
        runTest()
    }

    @objc private func openSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }

    @objc private func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Log.url])
    }
}

// MARK: - 起動

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
