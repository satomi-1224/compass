import AppKit
import ApplicationServices
import Foundation

/// `Cmd+V` の V。`kVK_ANSI_V` と同値。
private let keyCodeV: CGKeyCode = 9

/// 外部コマンドを実行する。
///
/// ホットキーの実行モデルは**外部コマンド実行のみ**（requirements.md 3.3）。
/// 組み込みアクションは UI を伴うため、ここでは扱わず呼び出し側が振り分ける。
///
/// `/bin/sh -c` を通すため、`~` や `$HOME` の展開、`&&` や末尾の `&` が
/// そのまま使える（requirements.md 7.3 の MagicBoard トグルがこれに依存する）。
public enum ActionRunner {

    /// コマンドを起動して**終了を待たない。**
    ///
    /// ランチャーは押した瞬間に返る必要がある。終了を待つと、起動の遅いアプリで
    /// 次のキー入力が詰まる。
    ///
    /// - Returns: 起動できたか。コマンド自体の成否ではない。
    @discardableResult
    public static func run(_ command: String, log: Log = .shared) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        // 出力を読む相手がいない。パイプを繋いだままにすると、書き込み側が
        // バッファを埋めた時点で止まる。
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            log.debug("実行: \(command)")
            return true
        } catch {
            log.error("実行できなかった: \(command) — \(error.localizedDescription)")
            return false
        }
    }

    /// 候補を選んだときの実行。
    public static func run(_ action: CandidateAction, log: Log = .shared) {
        switch action {
        case .open(let path):
            open(path: path, log: log)
        case .openURL(let url):
            open(url: url, log: log)
        case .paste(let text):
            paste(text, log: log)
        }
    }

    /// 既定のアプリで開く。アプリバンドルなら起動する。
    public static func open(path: String, log: Log = .shared) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        NSWorkspace.shared.open(url)
        log.debug("開く: \(url.path)")
    }

    public static func open(url: URL, log: Log = .shared) {
        NSWorkspace.shared.open(url)
        log.debug("開く: \(url.absoluteString)")
    }

    /// クリップボードへ載せて `Cmd+V` を送る。
    ///
    /// **アクセシビリティ権限が必要**（requirements.md 7.1）。権限が無いときは
    /// クリップボードに載せるところまでやって、手で `Cmd+V` できる状態にする。
    /// 黙って何も起きないより、載っているほうが復帰しやすい。
    ///
    /// 呼ぶ側は**検索窓を閉じてフォーカスが戻ってから**呼ぶこと。開いたまま送ると
    /// 自分の入力欄に貼られる。
    public static func paste(_ text: String, log: Log = .shared) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard AXIsProcessTrusted() else {
            log.error(
                "アクセシビリティ権限が無いため Cmd+V を送れない。"
                    + "クリップボードには載せたので手で貼れる")
            return
        }
        sendCommandV()
    }

    /// `Cmd+V` を HID レベルで送出する。権限が無ければ黙って無視される。
    private static func sendCommandV() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
