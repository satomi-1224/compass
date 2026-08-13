import AppKit
import Foundation
import Testing

@testable import CompassCore

@Suite("ActionRunner のコマンド実行")
struct ActionRunnerTests {

    /// ログを捨てる。テストの出力を汚さない。
    private let quiet = Log(minimum: .off)

    @Test("標準出力を取る")
    func capturesOutput() {
        #expect(ActionRunner.capture("echo hello", log: quiet) == "hello")
    }

    /// `git branch --show-current` は改行で終わる。貼るときは要らない。
    @Test("末尾の改行だけを落とす")
    func trimsTrailingNewlinesOnly() {
        #expect(ActionRunner.capture(#"printf 'a\n\n\n'"#, log: quiet) == "a")
        // 先頭の改行は残す。意図して空行で始まるスニペットを壊さない。
        #expect(ActionRunner.capture(#"printf '\na'"#, log: quiet) == "\na")
        // 途中の改行はそのまま。
        #expect(ActionRunner.capture(#"printf 'a\nb\n'"#, log: quiet) == "a\nb")
    }

    @Test("`sh -c` を通すのでシェルの機能が使える")
    func runsThroughShell() {
        #expect(ActionRunner.capture("echo a && echo b", log: quiet) == "a\nb")
        #expect(ActionRunner.capture("echo $((1 + 2))", log: quiet) == "3")
    }

    @Test("標準エラーは混ざらない")
    func ignoresStandardError() {
        #expect(ActionRunner.capture("echo out; echo err >&2", log: quiet) == "out")
    }

    @Test("出力が無ければ空文字")
    func emptyOutput() {
        #expect(ActionRunner.capture("true", log: quiet) == "")
    }

    /// 失敗しても出力は返す。終了コードは見ない（貼る中身が取れれば十分）。
    @Test("終了コードが非ゼロでも出力を返す")
    func returnsOutputOnFailure() {
        #expect(ActionRunner.capture("echo partial; exit 1", log: quiet) == "partial")
    }

    /// **読み切ってから待つ**という順序が守られているかを見る。先に
    /// `waitUntilExit` するとパイプが埋まった時点で互いに待ち合って返らない。
    @Test("パイプのバッファより大きい出力でも返る")
    func handlesLargeOutput() throws {
        let output = try #require(
            ActionRunner.capture("yes abcdefgh | head -20000", log: quiet))
        #expect(output.count == 20000 * 9 - 1)
    }

    /// 終わらないコマンドでスレッドを抱えたままにしない。
    @Test("時間切れで打ち切る", .timeLimit(.minutes(1)))
    func killsHangingCommand() {
        let started = Date()
        _ = ActionRunner.capture("sleep 30", timeout: 1, log: quiet)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("起動できないコマンドは nil")
    func returnsNilWhenShellFails() {
        // `sh -c` 自体は起動するので、出力が UTF-8 にならない場合を見る。
        #expect(ActionRunner.capture("printf '\\xff\\xfe'", log: quiet) == nil)
    }

    /// **compass が貼った内容をクリップボード履歴へ入れてはいけない。**
    /// スニペットの `body_command` でパスワードマネージャから取り出した値が、
    /// ユーザーがコピーしてもいないのに平文でディスクへ残ってしまう。
    ///
    /// `paste` ではなく `copyForPaste` を試す。`paste` は権限があると `Cmd+V` を
    /// 送出するので、テスト中に前面のアプリへ貼られてしまう。
    @MainActor
    @Test("貼る内容には履歴に残さない印を付ける")
    func marksPasteAsTransient() {
        let pasteboard = NSPasteboard.general
        // テストがユーザーのクリップボードを潰さないよう戻す。
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }

        ActionRunner.copyForPaste("secret")

        let types = pasteboard.types?.map(\.rawValue) ?? []
        #expect(types.contains("org.nspasteboard.TransientType"))
        #expect(pasteboard.string(forType: .string) == "secret")
    }
}
