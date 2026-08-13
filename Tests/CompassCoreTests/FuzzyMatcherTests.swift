import Testing

@testable import CompassCore

@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {

    private func candidate(_ title: String) -> Candidate {
        Candidate(
            id: title, title: title, icon: .file(path: "/\(title)"),
            action: .open(path: "/\(title)"))
    }

    // MARK: - マッチ判定

    @Test("部分列としてマッチする")
    func matchesSubsequence() {
        #expect(FuzzyMatcher.score("chr", in: "Google Chrome") != nil)
        #expect(FuzzyMatcher.score("gc", in: "Google Chrome") != nil)
        #expect(FuzzyMatcher.score("xyz", in: "Google Chrome") == nil)
    }

    @Test("大文字小文字を区別しない")
    func ignoresCase() {
        #expect(FuzzyMatcher.score("CHROME", in: "Google Chrome") != nil)
        #expect(FuzzyMatcher.score("chrome", in: "GOOGLE CHROME") != nil)
    }

    @Test("空のクエリは全てにマッチする")
    func emptyMatchesEverything() {
        #expect(FuzzyMatcher.score("", in: "anything")?.value == 0)
    }

    @Test("クエリが候補より長ければマッチしない")
    func rejectsTooLongQuery() {
        #expect(FuzzyMatcher.score("abcdef", in: "abc") == nil)
    }

    @Test("順序が違えばマッチしない")
    func requiresOrder() {
        #expect(FuzzyMatcher.score("cba", in: "abc") == nil)
    }

    // MARK: - スコアの付け方

    @Test("先頭からの連続一致を強く評価する")
    func prefersPrefixMatch() throws {
        let prefix = try #require(FuzzyMatcher.score("chr", in: "Chrome"))
        let scattered = try #require(FuzzyMatcher.score("chr", in: "Chart Reader"))
        #expect(prefix.value > scattered.value)
    }

    @Test("単語の頭を評価する")
    func prefersWordStart() throws {
        let boundary = try #require(FuzzyMatcher.score("gc", in: "Google Chrome"))
        let inner = try #require(FuzzyMatcher.score("gc", in: "Legacy"))
        #expect(boundary.value > inner.value)
    }

    /// "VSCode" の C を単語の頭として拾えないと、camelCase の名前が弱くなる。
    @Test("camelCase の境目を単語の頭として扱う")
    func treatsCamelCaseAsBoundary() throws {
        let camel = try #require(FuzzyMatcher.score("vc", in: "VSCode"))
        let plain = try #require(FuzzyMatcher.score("vc", in: "voice"))
        #expect(camel.value > plain.value)
    }

    @Test("同じ点なら短い候補が上に来る")
    func prefersShorterOnTie() {
        let result = FuzzyMatcher.filter(
            [candidate("Chromium"), candidate("Chrome")], query: "chrom", limit: 2)
        #expect(result.map(\.title) == ["Chrome", "Chromium"])
    }

    @Test("マッチした位置を返す")
    func reportsPositions() throws {
        let score = try #require(FuzzyMatcher.score("gc", in: "Google Chrome"))
        #expect(score.positions == [0, 7])
    }

    // MARK: - 絞り込み

    @Test("マッチしない候補を落とす")
    func dropsNonMatching() {
        let result = FuzzyMatcher.filter(
            [candidate("Safari"), candidate("Chrome")], query: "chr", limit: 9)
        #expect(result.map(\.title) == ["Chrome"])
    }

    @Test("クエリが空なら先頭から limit 件返す")
    func emptyQueryReturnsPrefix() {
        let candidates = (1...20).map { candidate("App \($0)") }
        #expect(FuzzyMatcher.filter(candidates, query: "", limit: 5).count == 5)
    }

    @Test("limit で打ち切る")
    func respectsLimit() {
        let candidates = (1...20).map { candidate("App \($0)") }
        #expect(FuzzyMatcher.filter(candidates, query: "app", limit: 3).count == 3)
        #expect(FuzzyMatcher.filter(candidates, query: "app", limit: 0).isEmpty)
    }

    /// **頻度学習をしない設計の核心。** 同じ入力に常に同じ結果を返す
    /// （requirements.md 3.2）。
    @Test("同じ入力に同じ順序を返す")
    func isDeterministic() {
        let candidates = (1...50).map { candidate("App \($0)") }
        let expected = FuzzyMatcher.filter(candidates, query: "ap", limit: 9).map(\.id)
        for _ in 0..<5 {
            #expect(FuzzyMatcher.filter(candidates, query: "ap", limit: 9).map(\.id) == expected)
        }
    }

    /// 並びが入力順に依存すると、Spotlight の到着順で結果が変わってしまう。
    @Test("入力の並び順に結果が依存しない")
    func independentOfInputOrder() {
        let names = ["Chrome", "Chromium", "Chroma", "Chronicle"]
        let forward = FuzzyMatcher.filter(names.map(candidate), query: "chro", limit: 9)
        let backward = FuzzyMatcher.filter(names.reversed().map(candidate), query: "chro", limit: 9)
        #expect(forward.map(\.title) == backward.map(\.title))
    }

    /// **同名のファイルは珍しくない**（`README.md` など）。名前だけで決めると
    /// `sorted(by:)` の不安定さと辞書のハッシュ順が漏れて、どれが limit に残るかが
    /// 実行ごとに変わる。
    @Test("同名の候補はパスで順序が決まる")
    func breaksTiesByPathWhenTitlesMatch() {
        let paths = ["/c/README.md", "/a/README.md", "/b/README.md"]
        let candidates = paths.map {
            Candidate(
                id: $0, title: "README.md", icon: .file(path: $0),
                action: .open(path: $0))
        }

        let forward = FuzzyMatcher.filter(candidates, query: "readme", limit: 3)
        let backward = FuzzyMatcher.filter(candidates.reversed(), query: "readme", limit: 3)

        #expect(forward.map(\.id) == ["/a/README.md", "/b/README.md", "/c/README.md"])
        #expect(forward.map(\.id) == backward.map(\.id))
        // limit で切っても同じものが残る。
        #expect(FuzzyMatcher.filter(candidates, query: "readme", limit: 1).map(\.id) == ["/a/README.md"])
    }
}
