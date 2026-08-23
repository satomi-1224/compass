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

    // MARK: - 別名

    /// アプリは Finder と同じ表示名（「システム設定」）を title にする。英名でも
    /// 引けないと `sys` で辿り着けなくなる。
    @Test("別名でも当たる")
    func matchesAliases() {
        let settings = Candidate(
            id: "s", title: "システム設定", icon: .symbol("gear"), action: .open(path: "/s"),
            aliases: ["System Settings"])

        #expect(FuzzyMatcher.score("設定", for: settings) != nil)
        #expect(FuzzyMatcher.score("sys", for: settings) != nil)
        #expect(FuzzyMatcher.score("zzz", for: settings) == nil)
    }

    /// 別名で当たった位置を title のハイライトに使うと、無関係な字が太る。
    @Test("別名で当たったときは位置を返さない")
    func aliasMatchHasNoPositions() throws {
        let settings = Candidate(
            id: "s", title: "システム設定", icon: .symbol("gear"), action: .open(path: "/s"),
            aliases: ["System Settings"])

        let byAlias = try #require(FuzzyMatcher.score("sys", for: settings))
        #expect(byAlias.positions.isEmpty)

        let byTitle = try #require(FuzzyMatcher.score("設定", for: settings))
        #expect(byTitle.positions == [4, 5])
    }

    /// title でも別名でも当たるなら、点の高いほうを採る。
    @Test("title と別名の良いほうを採る")
    func takesBestOfTitleAndAlias() throws {
        let candidate = Candidate(
            id: "c", title: "zzzzzzzzab", icon: .symbol("gear"), action: .open(path: "/c"),
            aliases: ["ab"])
        let byTitleOnly = try #require(FuzzyMatcher.score("ab", in: "zzzzzzzzab"))
        let best = try #require(FuzzyMatcher.score("ab", for: candidate))
        #expect(best.value > byTitleOnly.value)
    }

    @Test("別名は絞り込みにも効く")
    func filtersByAlias() {
        let candidates = [
            Candidate(
                id: "s", title: "システム設定", icon: .symbol("gear"),
                action: .open(path: "/s"), aliases: ["System Settings"]),
            Candidate(id: "o", title: "その他", icon: .symbol("gear"), action: .open(path: "/o")),
        ]
        #expect(FuzzyMatcher.filter(candidates, query: "system", limit: 9).map(\.id) == ["s"])
    }

    // MARK: - 照合用の畳み込み

    /// かな入力のまま打つと `ｃａｌ` になる。そのままでは 1 件も出ない。
    @Test("全角の英数は半角として扱う")
    func foldsFullWidthASCII() {
        #expect(FuzzyMatcher.score("ｃａｌ", in: "Calculator") != nil)
        #expect(FuzzyMatcher.score("ＳＡＦＡＲＩ", in: "Safari") != nil)
        #expect(FuzzyMatcher.score("cal", in: "Ｃａｌｃｕｌａｔｏｒ") != nil)
    }

    /// 変換せずに確定した「かれんだー」で「カレンダー」へ届く。
    @Test("ひらがなとカタカナを同じものとして扱う")
    func foldsKana() {
        #expect(FuzzyMatcher.score("かれんだー", in: "カレンダー") != nil)
        #expect(FuzzyMatcher.score("メモ", in: "めも") != nil)
        #expect(FuzzyMatcher.score("システム", in: "システム設定") != nil)
    }

    /// 位置をそのままタイトルへ戻してハイライトに使う。長さが変わると別の字が太る。
    @Test("畳んでも文字数は変わらない")
    func foldingKeepsLength() {
        for text in ["Ｃａｌ", "かれんだー", "İstanbul", "café", "🎉ab", "ｶﾞｷﾞ"] {
            #expect(
                FuzzyMatcher.folded(text).count == text.count,
                "\(text) の文字数が変わった")
        }
    }

    /// 全角スペースで区切っても当たるようにする。
    @Test("全角スペースは半角として扱う")
    func foldsIdeographicSpace() {
        #expect(FuzzyMatcher.score("a　b", in: "a b") != nil)
    }

    @Test("マッチ位置は元の文字列の位置を指す")
    func positionsPointAtOriginalText() throws {
        let score = try #require(FuzzyMatcher.score("だー", in: "カレンダー"))
        #expect(score.positions == [3, 4])
    }
}
