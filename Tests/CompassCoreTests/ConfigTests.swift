import Testing

@testable import CompassCore

@Suite("Config のパース")
struct ConfigTests {

    /// requirements.md 4章の設定例をそのまま読む。
    /// **ドキュメントと実装が乖離したらここで落ちる。**
    @Test("要件に載っている設定例を読める")
    func parsesDocumentedExample() throws {
        let toml = """
            [appearance]
            display     = "main"
            width       = 680
            max_results = 9

            [search]
            matching = "fuzzy"

            [search.files]
            scopes      = ["~"]
            max_results = 20

            [clipboard]
            enabled       = true
            max_items     = 50
            poll_interval = 0.8

            [[search.keywords]]
            prefix = "f"
            kind   = "file"

            [[search.keywords]]
            prefix = "g"
            kind   = "web"
            url    = "https://www.google.com/search?q={query}"
            """

        let config = try Config.parse(toml)

        #expect(config.appearance.display == .main)
        #expect(config.appearance.width == 680)
        #expect(config.appearance.maxResults == 9)
        #expect(config.search.matching == .fuzzy)
        #expect(config.search.files.scopes == ["~"])
        #expect(config.search.files.maxResults == 20)
        #expect(config.clipboard.enabled)
        #expect(config.clipboard.maxItems == 50)
        #expect(config.clipboard.pollInterval == 0.8)
        #expect(config.search.keywords.count == 2)
        #expect(config.search.keywords[0] == Config.Keyword(prefix: "f", kind: .file))
    }

    /// home-manager の `pkgs.formats.toml` が生成する形をそのまま読む。
    /// **`[search.files]` のあとに `[[search.keywords]]` が来る並び**でも、
    /// 配列テーブルは `search` 直下として解釈される。
    @Test("home-manager が生成する TOML を読める")
    func parsesGeneratedTOML() throws {
        let toml = """
            [appearance]
            max_results = 9
            width = 680

            [clipboard]
            enabled = true
            max_items = 50
            poll_interval = 0.8

            [search.files]
            scopes = ["~"]

            [[search.keywords]]
            kind = "web"
            prefix = "g"
            url = "https://www.google.com/search?q={query}"
            """

        let config = try Config.parse(toml)

        #expect(config.appearance.maxResults == 9)
        #expect(config.appearance.width == 680)
        #expect(config.clipboard.maxItems == 50)
        #expect(config.search.files.scopes == ["~"])
        #expect(config.search.keywords.count == 1)
        #expect(config.search.keywords[0].prefix == "g")
        #expect(config.search.keywords[0].kind == .web)
    }

    @Test("空の TOML は既定値になる")
    func emptyIsDefault() throws {
        #expect(try Config.parse("") == Config())
    }

    @Test("書かれた項目だけが上書きされる")
    func partialOverride() throws {
        let config = try Config.parse("[clipboard]\nenabled = false")
        #expect(config.clipboard.enabled == false)
        // 触れていない項目は既定のまま。
        #expect(config.clipboard.maxItems == Config.Clipboard().maxItems)
        #expect(config.appearance.width == Config.Appearance().width)
    }

    @Test("TOML として壊れていれば失敗する")
    func rejectsBrokenTOML() {
        #expect(throws: ConfigIssues.self) {
            try Config.parse("[appearance")
        }
    }

    /// 丸めると「設定したのに効いていない」状態になり、正常時に黙る設計では気づけない。
    @Test("範囲外の値は丸めずにエラーにする")
    func rejectsOutOfRange() throws {
        let issues = try #require(throws: ConfigIssues.self) {
            try Config.parse("[appearance]\nmax_results = 0")
        }
        #expect(issues.items.count == 1)
        #expect(issues.items[0].file == .config)
        #expect(issues.items[0].detail.contains("max_results"))
    }

    @Test("不明な値は候補を添えて報告する")
    func reportsUnknownValueWithCandidates() throws {
        let issues = try #require(throws: ConfigIssues.self) {
            try Config.parse(#"[search]\#nmatching = "prefix""#)
        }
        #expect(issues.items[0].detail.contains("fuzzy"))
    }

    /// 1 件直すたびに次が出るのでは、通知しか手がかりのない常駐では原因を追いにくい。
    @Test("複数の不備をまとめて報告する")
    func collectsMultipleIssues() throws {
        let toml = """
            [appearance]
            width       = 10
            max_results = 999
            """
        let issues = try #require(throws: ConfigIssues.self) { try Config.parse(toml) }
        #expect(issues.items.count == 2)
    }

    @Test("探索範囲が空ならエラー")
    func rejectsEmptyScopes() {
        #expect(throws: ConfigIssues.self) {
            try Config.parse("[search.files]\nscopes = []")
        }
    }

    /// 通知しか手がかりが無いので、値が空文字のときは位置を伝える必要がある。
    @Test("空文字の探索範囲は位置を報告する")
    func reportsBlankScopePosition() throws {
        let issues = try #require(throws: ConfigIssues.self) {
            try Config.parse(#"[search.files]\#nscopes = ["~", ""]"#)
        }
        #expect(issues.items[0].detail.contains("2 番目"))
    }

    // MARK: - キーワード

    @Test("キーワードは書かれていれば置き換える")
    func keywordsReplaceDefaults() throws {
        let toml = """
            [[search.keywords]]
            prefix = "d"
            kind   = "file"
            """
        let config = try Config.parse(toml)
        #expect(config.search.keywords == [Config.Keyword(prefix: "d", kind: .file)])
    }

    @Test("web には {query} を含む url が必要")
    func webKeywordRequiresURLTemplate() throws {
        let missing = try #require(throws: ConfigIssues.self) {
            try Config.parse(#"[[search.keywords]]\#nprefix = "g"\#nkind = "web""#)
        }
        #expect(missing.items[0].detail.contains("url"))

        let noPlaceholder = try #require(throws: ConfigIssues.self) {
            try Config.parse(
                #"""
                [[search.keywords]]
                prefix = "g"
                kind   = "web"
                url    = "https://example.com/search"
                """#)
        }
        #expect(noPlaceholder.items[0].detail.contains("{query}"))
    }

    @Test("prefix の重複はエラー")
    func rejectsDuplicatePrefix() {
        let toml = """
            [[search.keywords]]
            prefix = "f"
            kind   = "file"

            [[search.keywords]]
            prefix = "f"
            kind   = "file"
            """
        #expect(throws: ConfigIssues.self) { try Config.parse(toml) }
    }

    /// 先頭トークンで判定するため、空白を含む prefix は入力から切り出せない。
    @Test("prefix に空白は使えない")
    func rejectsPrefixWithWhitespace() {
        #expect(throws: ConfigIssues.self) {
            try Config.parse(#"[[search.keywords]]\#nprefix = "g h"\#nkind = "file""#)
        }
    }

    /// 黙って無視すると、書いたつもりの url が効かない状態に気づけない。
    @Test("file キーワードに url を書いたらエラー")
    func rejectsURLOnFileKeyword() throws {
        let issues = try #require(throws: ConfigIssues.self) {
            try Config.parse(
                #"""
                [[search.keywords]]
                prefix = "f"
                kind   = "file"
                url    = "https://example.com/?q={query}"
                """#)
        }
        #expect(issues.items[0].detail.contains("url"))
    }

    @Test("既定のキーワードは file と web が揃っている")
    func defaultKeywordsAreUsable() {
        let defaults = Config.Keyword.defaults
        #expect(defaults.contains { $0.kind == .file })
        #expect(defaults.contains { $0.kind == .web })
        // web には必ずテンプレートがある。
        for keyword in defaults where keyword.kind == .web {
            #expect(keyword.url?.contains("{query}") == true)
        }
        // prefix は重複しない。
        #expect(Set(defaults.map(\.prefix)).count == defaults.count)
    }

    // MARK: - URL の組み立て

    @Test("検索語を URL に差し込む")
    func buildsSearchURL() {
        let keyword = Config.Keyword(
            prefix: "g", kind: .web, url: "https://www.google.com/search?q={query}")
        #expect(
            keyword.resolvedURL(for: "swift")?.absoluteString
                == "https://www.google.com/search?q=swift")
    }

    @Test("空白や記号をエスケープする")
    func escapesQuery() throws {
        let keyword = Config.Keyword(
            prefix: "g", kind: .web, url: "https://example.com/?q={query}")
        let url = try #require(keyword.resolvedURL(for: "a b&c=d"))
        #expect(url.absoluteString == "https://example.com/?q=a%20b%26c%3Dd")
    }

    @Test("file キーワードは URL を持たない")
    func fileKeywordHasNoURL() {
        #expect(Config.Keyword(prefix: "f", kind: .file).resolvedURL(for: "x") == nil)
    }
}
