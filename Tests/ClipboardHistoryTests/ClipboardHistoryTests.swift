import Foundation
import Testing

@testable import ClipboardHistory
@testable import CompassCore

@MainActor
@Suite("ClipboardHistory")
struct ClipboardHistoryTests {

    private func makeStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("compass-clip-\(UUID().uuidString).json")
    }

    private func makeHistory(
        at url: URL, maxItems: Int = 50, enabled: Bool = true
    ) -> ClipboardHistory {
        ClipboardHistory(
            settings: { Config.Clipboard(enabled: enabled, maxItems: maxItems) },
            storeURL: url
        )
    }

    @Test("新しいものが先頭に来る")
    func newestFirst() {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let history = makeHistory(at: url)
        history.record("a")
        history.record("b")

        #expect(history.items == ["b", "a"])
    }

    /// 同じ内容が並ぶと履歴が埋まる（requirements.md 3.4）。
    @Test("同じ内容は消して先頭へ移す")
    func deduplicates() {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let history = makeHistory(at: url)
        history.record("a")
        history.record("b")
        history.record("a")

        #expect(history.items == ["a", "b"])
    }

    @Test("上限を超えたら古いものを捨てる")
    func respectsMaxItems() {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let history = makeHistory(at: url, maxItems: 3)
        for text in ["a", "b", "c", "d"] { history.record(text) }

        #expect(history.items == ["d", "c", "b"])
    }

    /// 現行 `hs.settings` 相当。再起動しても残る（requirements.md 3.4）。
    @Test("再起動しても履歴が残る")
    func persistsAcrossRestart() {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = makeHistory(at: url)
        first.record("a")
        first.record("b")
        // 書き込みはバックグラウンド。読み返す前に終わらせる。
        first.waitForWrites()

        let second = makeHistory(at: url)
        #expect(second.items == ["b", "a"])
    }

    /// 履歴は機密を含みうる。他のユーザーから読めてはいけない。
    @Test("保存ファイルは所有者だけが読める")
    func storeIsPrivate() throws {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let history = makeHistory(at: url)
        history.record("secret")
        history.waitForWrites()

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value == 0o600)
    }

    @Test("壊れた保存ファイルでも空から始まる")
    func toleratesCorruptStore() throws {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "これは JSON ではない".write(to: url, atomically: true, encoding: .utf8)

        #expect(makeHistory(at: url).items.isEmpty)
    }

    @Test("enabled = false なら監視を始めない")
    func disabledDoesNotStart() {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let history = makeHistory(at: url, enabled: false)
        history.start()
        #expect(history.isRunning == false)
        history.stop()
    }

    @Test("enabled = true なら監視を始める")
    func enabledStarts() {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let history = makeHistory(at: url)
        history.start()
        #expect(history.isRunning)
        history.stop()
        #expect(history.isRunning == false)
    }

    @Test("候補は新しい順に並ぶ")
    func candidatesAreNewestFirst() {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let history = makeHistory(at: url)
        history.record("a")
        history.record("b")

        let candidates = history.candidates()
        #expect(candidates.map(\.title) == ["b", "a"])
        #expect(candidates[0].action == .paste("b"))
    }

    /// アイコンを持たない候補が混ざると、その行だけ文字の左に空白が空いて
    /// 一覧が崩れて見える。
    @Test("候補は必ずアイコンを持つ")
    func candidatesAlwaysHaveIcon() {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let history = makeHistory(at: url)
        history.record("a")

        #expect(history.candidates()[0].icon == .symbol("doc.on.clipboard"))
    }

    /// 複数行のテキストをそのまま出すと一覧の行が崩れる。
    @Test("候補の表示は 1 行に畳む")
    func candidateTitleIsFolded() {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let history = makeHistory(at: url)
        history.record("一行目\n二行目\t三行目")

        #expect(history.candidates()[0].title == "一行目 二行目 三行目")
        // 貼る中身は元のまま。
        #expect(history.candidates()[0].action == .paste("一行目\n二行目\t三行目"))
    }

    @Test("clear で空にする")
    func clearsHistory() {
        let url = makeStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let history = makeHistory(at: url)
        history.record("a")
        history.clear()
        history.waitForWrites()

        #expect(history.items.isEmpty)
        #expect(makeHistory(at: url).items.isEmpty)
    }
}

@Suite("TextSummary")
struct TextSummaryTests {

    @Test("改行とタブを畳む")
    func foldsWhitespace() {
        #expect(TextSummary.line(of: "a\nb\tc") == "a b c")
        #expect(TextSummary.line(of: "a\r\nb") == "a b")
    }

    @Test("続いた空白を 1 つにまとめる")
    func collapsesRuns() {
        #expect(TextSummary.line(of: "a    b") == "a b")
    }

    @Test("長すぎれば切って印を付ける")
    func truncates() {
        let summary = TextSummary.line(of: String(repeating: "x", count: 200), limit: 10)
        #expect(summary == String(repeating: "x", count: 10) + "…")
    }

    @Test("短ければそのまま")
    func keepsShortText() {
        #expect(TextSummary.line(of: "hello") == "hello")
    }

    /// **全長を走査しない。** クリップボード履歴には数 MB のテキストが入りうる。
    /// 50 件ぶん畳もうとすると、履歴を開いた瞬間に窓が固まる。
    @Test("巨大な入力でも一瞬で畳む")
    func foldsHugeTextQuickly() {
        let huge = String(repeating: "あ", count: 4_000_000)
        let start = Date()
        let summary = TextSummary.line(of: huge, limit: 120)
        #expect(summary.count == 121)  // 120 文字 + 省略記号
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    /// 切り出した先に中身が残っていても、省略したことは示す。
    @Test("空白ばかりでも省略を示す")
    func marksClippedWhitespace() {
        let text = String(repeating: " ", count: 5_000) + "末尾"
        #expect(TextSummary.line(of: text, limit: 10) == "…")
    }
}
