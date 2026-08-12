import Testing

@testable import CompassCore

@Suite("QueryParser")
struct QueryParserTests {

    private let keywords = Config.Keyword.defaults

    @Test("素の入力はアプリ検索")
    func plainInputSearchesApps() {
        let parsed = QueryParser.parse("chr", keywords: keywords)
        #expect(parsed == QueryParser.Parsed(mode: .apps, query: "chr"))
    }

    /// キーワードだけの時点で切り替えると、`g` で始まるアプリを探せなくなる。
    @Test("キーワードだけではモードを変えない")
    func keywordAloneStaysInApps() {
        #expect(QueryParser.parse("g", keywords: keywords).mode == .apps)
        #expect(QueryParser.parse("f", keywords: keywords).mode == .apps)
        #expect(QueryParser.parse("gh", keywords: keywords).mode == .apps)
    }

    @Test("空白が続いたらモードを変える")
    func switchesOnSpace() throws {
        let parsed = QueryParser.parse("g swift", keywords: keywords)
        #expect(parsed.query == "swift")
        guard case .web(let keyword) = parsed.mode else {
            Issue.record("web モードにならなかった: \(parsed.mode)")
            return
        }
        #expect(keyword.prefix == "g")
    }

    @Test("キーワードの直後が空白ならクエリは空")
    func emptyQueryAfterKeyword() {
        let parsed = QueryParser.parse("g ", keywords: keywords)
        #expect(parsed.query == "")
        #expect(parsed.mode != .apps)
    }

    @Test("2 つ目以降の空白はクエリに残す")
    func keepsRemainingSpaces() {
        #expect(QueryParser.parse("g a b", keywords: keywords).query == "a b")
    }

    @Test("file キーワードはファイル検索")
    func fileKeyword() {
        let parsed = QueryParser.parse("f report", keywords: keywords)
        #expect(parsed.mode == .files)
        #expect(parsed.query == "report")
    }

    @Test("知らないキーワードはアプリ検索のまま")
    func unknownKeywordStaysInApps() {
        let parsed = QueryParser.parse("zz foo", keywords: keywords)
        #expect(parsed.mode == .apps)
        // 切り出さずに入力全体をクエリとして扱う。
        #expect(parsed.query == "zz foo")
    }

    @Test("キーワードが無ければ常にアプリ検索")
    func noKeywordsMeansApps() {
        #expect(QueryParser.parse("g swift", keywords: []).mode == .apps)
        #expect(QueryParser.parse("g swift", keywords: []).query == "g swift")
    }

    /// 長い prefix と短い prefix が両方あるとき、完全一致で選ぶ。
    @Test("prefix は完全一致で選ぶ")
    func matchesPrefixExactly() throws {
        let parsed = QueryParser.parse("gh swift", keywords: keywords)
        guard case .web(let keyword) = parsed.mode else {
            Issue.record("web モードにならなかった")
            return
        }
        #expect(keyword.prefix == "gh")
        #expect(keyword.url?.contains("github") == true)
    }

    @Test("空の入力はアプリ検索でクエリも空")
    func emptyInput() {
        #expect(QueryParser.parse("", keywords: keywords) == .init(mode: .apps, query: ""))
    }
}
