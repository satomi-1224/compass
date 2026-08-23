import AppKit
import ApplicationServices
import Foundation

/// `Cmd+V` の V。`kVK_ANSI_V` と同値。
private let keyCodeV: CGKeyCode = 9

/// クリップボード管理ツールに「履歴へ残すな」と伝える型
/// （[nspasteboard.org](http://nspasteboard.org/) の慣例）。
private let transientPasteboardType = "org.nspasteboard.TransientType"

extension String {
    /// 末尾の改行だけを落とす。
    ///
    /// `trimmingCharacters(in: .newlines)` は先頭も削るため使わない。
    /// 意図して先頭を空行で始めるスニペットを壊さないようにする。
    func trimmingTrailingNewlines() -> String {
        var result = self
        while result.hasSuffix("\n") || result.hasSuffix("\r") {
            result.removeLast()
        }
        return result
    }
}

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
        case .pasteCommandOutput(let command):
            pasteOutput(of: command, log: log)
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
        copyForPaste(text)

        guard AXIsProcessTrusted() else {
            log.error(
                "アクセシビリティ権限が無いため Cmd+V を送れない。"
                    + "クリップボードには載せたので手で貼れる")
            return
        }
        sendCommandV()
        log.debug("Cmd+V を送出した")
    }

    /// 外部コマンドの出力をクリップボードへ載せて `Cmd+V` を送る。
    ///
    /// **メインスレッドを止めない。** 出力が揃うまで貼れないが、その間 UI が
    /// 固まると押した感触が悪い。裏で走らせて揃ってから貼る。
    public static func pasteOutput(
        of command: String, timeout: TimeInterval = 5, log: Log = .shared
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let output = capture(command, timeout: timeout, log: log) else { return }
            // **何も出さないコマンドは、選ばれたのに何も起きなかったのと同じ。**
            // 不可視の常駐なので、黙ると原因を追う手がかりが無い。
            guard !output.isEmpty else {
                // 通知そのものがログにも残るので、ここでは書かない。
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        Notifier.shared.report(
                            title: "スニペットのコマンドが何も出力しなかった", body: command)
                    }
                }
                return
            }
            DispatchQueue.main.async {
                paste(output, log: log)
            }
        }
    }

    /// コマンドの標準出力を読む。呼び出し元のスレッドをブロックする。
    ///
    /// テストから直接呼べるように internal にしてある。
    static func capture(
        _ command: String, timeout: TimeInterval = 5, log: Log = .shared
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            log.error("実行できなかった: \(command) — \(error.localizedDescription)")
            return nil
        }

        // 終わらないコマンドでスレッドを抱えたままにしない。
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            log.error("\(Int(timeout)) 秒で終わらなかったので止めた: \(command)")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        // **読み切ってから待つ。** 先に waitUntilExit すると、パイプのバッファが
        // 埋まった時点で子プロセスが書き込みで止まり、互いに待ち合う。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        guard let text = String(data: data, encoding: .utf8) else {
            log.error("出力を UTF-8 として読めなかった: \(command)")
            return nil
        }
        // コマンド出力は改行で終わるが、貼るときは要らない。
        return text.trimmingTrailingNewlines()
    }

    /// クリップボードへ載せる。**送出はしない**（テストから安全に呼べる）。
    ///
    /// **「履歴へ残すな」の印を付ける。** compass 自身が貼った内容がクリップボード
    /// 履歴へ入ると、スニペットの `body_command` で取り出した秘密（パスワード
    /// マネージャの読み出しなど）が平文でディスクに残る。貼る元（スニペット定義や
    /// 履歴そのもの）は別に残っているので、履歴に入らなくても失うものはない。
    static func copyForPaste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            "", forType: NSPasteboard.PasteboardType(transientPasteboardType))
        pasteboard.setString(text, forType: .string)
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
