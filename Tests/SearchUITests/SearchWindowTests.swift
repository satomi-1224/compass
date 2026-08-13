import AppKit
import CompassCore
import Testing

@testable import SearchUI

@MainActor
@Suite("SearchWindow のキー操作")
struct SearchWindowTests {

    private func candidates(_ count: Int) -> [Candidate] {
        (1...count).map {
            Candidate(id: "\($0)", title: "App \($0)", action: .open(path: "/\($0)"))
        }
    }

    /// 候補を入れた窓を作る。**`present` は呼ばない**（画面に出さずに検証する）。
    private func makeWindow(candidateCount: Int = 3) -> SearchWindow {
        let window = SearchWindow(width: 680, maxVisibleRows: 9)
        window.setCandidates(candidates(candidateCount))
        return window
    }

    /// `doCommandBy` は引数のコントロールとテキストビューを見ていない。
    @discardableResult
    private func send(_ selector: Selector, to window: SearchWindow) -> Bool {
        window.control(NSControl(), textView: NSTextView(), doCommandBy: selector)
    }

    // MARK: - 選択

    @Test("候補を入れると先頭が選ばれる")
    func selectsFirstCandidate() {
        #expect(makeWindow().selected?.id == "1")
    }

    /// 絞り込むたびに前の選択位置を引き継ぐと、意図しない候補が実行される。
    @Test("候補を差し替えると先頭に戻る")
    func resetsSelectionOnUpdate() {
        let window = makeWindow()
        send(#selector(NSResponder.moveDown(_:)), to: window)
        #expect(window.selected?.id == "2")

        window.setCandidates(candidates(3))
        #expect(window.selected?.id == "1")
    }

    @Test("候補が無ければ選択も無い")
    func noSelectionWhenEmpty() {
        let window = SearchWindow(width: 680, maxVisibleRows: 9)
        window.setCandidates([])
        #expect(window.selected == nil)
    }

    @Test("↓ で次の候補へ進む")
    func moveDown() {
        let window = makeWindow()
        send(#selector(NSResponder.moveDown(_:)), to: window)
        #expect(window.selected?.id == "2")
        send(#selector(NSResponder.moveDown(_:)), to: window)
        #expect(window.selected?.id == "3")
    }

    /// **端で止める。** 巻き戻すと押し続けたときの行き先が読めない。
    @Test("↓ は末尾で止まる")
    func stopsAtLastCandidate() {
        let window = makeWindow()
        for _ in 0..<10 { send(#selector(NSResponder.moveDown(_:)), to: window) }
        #expect(window.selected?.id == "3")
    }

    @Test("↑ は先頭で止まる")
    func stopsAtFirstCandidate() {
        let window = makeWindow()
        send(#selector(NSResponder.moveDown(_:)), to: window)
        for _ in 0..<10 { send(#selector(NSResponder.moveUp(_:)), to: window) }
        #expect(window.selected?.id == "1")
    }

    @Test("候補が無いときに矢印を押しても落ちない")
    func toleratesArrowsWithoutCandidates() {
        let window = SearchWindow(width: 680, maxVisibleRows: 9)
        window.setCandidates([])
        send(#selector(NSResponder.moveDown(_:)), to: window)
        send(#selector(NSResponder.moveUp(_:)), to: window)
        #expect(window.selected == nil)
    }

    // MARK: - 実行と取り消し

    @Test("Enter で onSubmit が呼ばれる")
    func submitOnEnter() {
        let window = makeWindow()
        var submitted = 0
        window.onSubmit = { submitted += 1 }

        #expect(send(#selector(NSResponder.insertNewline(_:)), to: window))
        #expect(submitted == 1)
    }

    @Test("Esc で onCancel が呼ばれる")
    func cancelOnEscape() {
        let window = makeWindow()
        var cancelled = 0
        window.onCancel = { cancelled += 1 }

        #expect(send(#selector(NSResponder.cancelOperation(_:)), to: window))
        #expect(cancelled == 1)
    }

    /// 捕まえたキーだけ true を返す。それ以外は field editor に任せる
    /// （でないと文字が打てない）。
    @Test("扱わないキーは field editor に渡す")
    func passesThroughOtherCommands() {
        let window = makeWindow()
        #expect(send(#selector(NSResponder.deleteBackward(_:)), to: window) == false)
        #expect(send(#selector(NSResponder.moveLeft(_:)), to: window) == false)
        #expect(send(#selector(NSResponder.insertTab(_:)), to: window) == false)
    }

    // MARK: - 画面に収める

    /// `max_results` は 50 まで許すので、そのままだと候補が画面外へ出て選べない。
    @Test("画面に収まる行数を返す")
    func rowsThatFitOnScreen() {
        // 900pt の画面: 900 * 0.82 - 56 - 1 - 20 = 661 → 661 / 48 = 13 行
        #expect(SearchWindow.rowsThatFit(in: NSRect(x: 0, y: 0, width: 1440, height: 900)) == 13)
        // 大きい画面ではその分入る。
        #expect(SearchWindow.rowsThatFit(in: NSRect(x: 0, y: 0, width: 3840, height: 2160)) > 13)
    }

    /// 入力した文字と候補のタイトルの左端が揃っていないと、全体が雑に見える。
    @Test("入力欄と候補行のテキスト左端が同じ値から来る")
    func textInsetIsShared() {
        #expect(
            Metrics.textInset
                == Metrics.horizontalPadding + Metrics.iconWidth + Metrics.iconGap)
        #expect(CandidateTable.rowHeight == Metrics.rowHeight)
    }

    /// 0 を返すと窓が作れない。極端に低い画面でも 1 行は残す。
    @Test("収まらない画面でも 1 行は返す")
    func returnsAtLeastOneRow() {
        #expect(SearchWindow.rowsThatFit(in: NSRect(x: 0, y: 0, width: 800, height: 100)) == 1)
        #expect(SearchWindow.rowsThatFit(in: .zero) == 1)
    }
}
