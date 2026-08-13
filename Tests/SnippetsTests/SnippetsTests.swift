import Foundation
import Testing

@testable import CompassCore
@testable import Snippets

@Suite("SnippetExpander")
struct SnippetExpanderTests {

    /// 2026-02-02 頃。年末年始を避けているので、タイムゾーンで年が動かない。
    private let reference = Date(timeIntervalSince1970: 1_770_000_000)

    @Test("{date} は yyyy-MM-dd の形になる")
    func dateShape() {
        let result = SnippetExpander.expand("{date}", now: reference)
        #expect(result.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil)
    }

    @Test("{time} は HH:mm の形になる")
    func timeShape() {
        let result = SnippetExpander.expand("{time}", now: reference)
        #expect(result.wholeMatch(of: /\d{2}:\d{2}/) != nil)
    }

    @Test("{datetime} は日付と時刻を続ける")
    func dateTimeShape() {
        let result = SnippetExpander.expand("{datetime}", now: reference)
        #expect(result.wholeMatch(of: /\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/) != nil)
    }

    /// 現行 Hammerspoon の `now`（`os.date("%Y-%m-%d")`）がこれで置き換わる。
    @Test("要件の設定例をそのまま展開できる")
    func expandsDocumentedExample() {
        let result = SnippetExpander.expand("{date:yyyy-MM-dd}", now: reference)
        #expect(result.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil)
    }

    @Test("書式を指定できる")
    func acceptsCustomFormat() {
        #expect(SnippetExpander.expand("{date:yyyy}", now: reference) == "2026")
    }

    /// 端末のロケールが日本語でも `yyyy` が和暦年になってはいけない。
    @Test("暦とロケールを固定する")
    func usesGregorianCalendar() {
        let year = SnippetExpander.expand("{date:yyyy}", now: reference)
        #expect(year == "2026")
        // 和暦なら "8" などになる。
        #expect(year.count == 4)
    }

    @Test("同じ時刻を渡せば同じ結果になる")
    func isDeterministic() {
        let template = "{date} {time} {datetime}"
        let first = SnippetExpander.expand(template, now: reference)
        #expect(SnippetExpander.expand(template, now: reference) == first)
    }

    @Test("1 つのテキストに複数書ける")
    func expandsMultiplePlaceholders() {
        let result = SnippetExpander.expand("{date:yyyy}/{date:yyyy}", now: reference)
        #expect(result == "2026/2026")
    }

    /// `{foo}` をリテラルとして書きたいことがある。
    @Test("知らないプレースホルダはそのまま残す")
    func keepsUnknownPlaceholder() {
        #expect(SnippetExpander.expand("{foo}", now: reference) == "{foo}")
        #expect(SnippetExpander.expand("a{bar:x}b", now: reference) == "a{bar:x}b")
    }

    /// 空文字に展開すると、書いたものが黙って消える。
    @Test("空の書式は既定として扱う")
    func treatsEmptyArgumentAsAbsent() {
        #expect(
            SnippetExpander.expand("{date:}", now: reference)
                == SnippetExpander.expand("{date}", now: reference))
        #expect(
            SnippetExpander.expand("{time:}", now: reference)
                == SnippetExpander.expand("{time}", now: reference))
    }

    @Test("プレースホルダが無ければそのまま返す")
    func passesThroughPlainText() {
        #expect(SnippetExpander.expand("@example", now: reference) == "@example")
        #expect(SnippetExpander.expand("", now: reference) == "")
    }

    @Test("{uuid} は小文字で毎回変わる")
    func uuidIsLowercaseAndUnique() {
        let first = SnippetExpander.expand("{uuid}")
        #expect(first == first.lowercased())
        #expect(first.count == 36)
        #expect(SnippetExpander.expand("{uuid}") != first)
    }

    @Test("大文字で書いても解釈する")
    func acceptsUppercaseName() {
        #expect(SnippetExpander.expand("{DATE:yyyy}", now: reference) == "2026")
    }

    @Test("書ける一覧は空でない")
    func placeholderListIsUsable() {
        #expect(!SnippetExpander.placeholders.isEmpty)
        #expect(SnippetExpander.placeholders.contains { $0.syntax == "{date}" })
    }
}

@MainActor
@Suite("SnippetLibrary")
struct SnippetLibraryTests {

    private let reference = Date(timeIntervalSince1970: 1_770_000_000)

    @Test("body は展開して候補にする")
    func expandsTextBody() {
        let library = SnippetLibrary(definitions: {
            [SnippetDefinition(title: "now", body: .text("{date:yyyy}"))]
        })

        let candidates = library.candidates(now: reference)
        #expect(candidates.count == 1)
        #expect(candidates[0].title == "now")
        // 何が貼られるかを一覧で見せる。
        #expect(candidates[0].subtitle == "2026")
        #expect(candidates[0].action == .paste("2026"))
    }

    /// 一覧を開くだけで走らせると、副作用のあるコマンドで困る。
    @Test("body_command は実行せずに候補にする")
    func doesNotRunCommand() {
        let library = SnippetLibrary(definitions: {
            [SnippetDefinition(title: "branch", body: .command("git branch --show-current"))]
        })

        let candidates = library.candidates(now: reference)
        #expect(candidates[0].action == .pasteCommandOutput("git branch --show-current"))
        // 一覧では実行しないので、何が走るかを見せる。
        #expect(candidates[0].subtitle == "$ git branch --show-current")
    }

    @Test("定義が無ければ候補も無い")
    func emptyDefinitions() {
        #expect(SnippetLibrary(definitions: { [] }).candidates().isEmpty)
    }

    /// アイコンを持たない候補が混ざると、その行だけ文字の左に空白が空く。
    /// 外部コマンドを走らせるものは見た目で区別できるようにする。
    @Test("候補は必ずアイコンを持ち、種類で描き分ける")
    func candidatesAlwaysHaveIcon() {
        let library = SnippetLibrary(definitions: {
            [
                SnippetDefinition(title: "text", body: .text("a")),
                SnippetDefinition(title: "command", body: .command("echo a")),
            ]
        })

        let candidates = library.candidates(now: reference)
        #expect(candidates[0].icon == .symbol("text.quote"))
        #expect(candidates[1].icon == .symbol("terminal"))
    }

    @Test("設定の順序を保つ")
    func keepsDefinitionOrder() {
        let library = SnippetLibrary(definitions: {
            [
                SnippetDefinition(title: "a", body: .text("1")),
                SnippetDefinition(title: "b", body: .text("2")),
            ]
        })
        #expect(library.candidates(now: reference).map(\.title) == ["a", "b"])
    }
}
