import Testing

@testable import CompassCore
@testable import SnippetsPlugin

@Suite("SnippetDefinition のパース")
struct SnippetDefinitionTests {

    @Test("設定例を読める")
    func parsesDocumentedExample() throws {
        let toml = """
            [[snippets]]
            title = "now"
            body  = "{date:yyyy-MM-dd}"

            [[snippets]]
            title = "account"
            body  = "@example"

            [[snippets]]
            title = "branch"
            body_command = "git branch --show-current"
            """

        let snippets = try SnippetDefinition.parseAll(toml)

        #expect(snippets.count == 3)
        #expect(snippets[0] == SnippetDefinition(title: "now", body: .text("{date:yyyy-MM-dd}")))
        #expect(snippets[1].body == .text("@example"))
        #expect(snippets[2].body == .command("git branch --show-current"))
    }

    @Test("Nix が生成するキー順でも読める")
    func parsesGeneratedTOML() throws {
        let toml = """
            [[snippets]]
            body = "{date}"
            title = "now"

            [[snippets]]
            body = "@example"
            title = "account"

            [[snippets]]
            body_command = "git branch --show-current"
            title = "branch"
            """

        let snippets = try SnippetDefinition.parseAll(toml)
        #expect(snippets.map(\.title) == ["now", "account", "branch"])
        #expect(snippets[2].body == .command("git branch --show-current"))
    }

    @Test("空なら 0 件")
    func emptyIsNoSnippets() throws {
        #expect(try SnippetDefinition.parseAll("").isEmpty)
    }

    @Test("body と body_command は同時に書けない")
    func rejectsBothBodies() throws {
        let issues = try #require(
            thrownIssues {
                try SnippetDefinition.parseAll(
                    #"[[snippets]]\#ntitle = "x"\#nbody = "a"\#nbody_command = "b""#)
            })
        #expect(issues.items[0].file == SnippetPlugin.configurationFile)
        #expect(issues.items[0].detail.contains("同時"))
    }

    @Test("body も body_command も無ければエラー")
    func rejectsMissingBody() throws {
        let issues = try #require(
            thrownIssues {
                try SnippetDefinition.parseAll(#"[[snippets]]\#ntitle = "x""#)
            })
        #expect(issues.items[0].detail.contains("body"))
    }

    @Test("title が無ければエラー")
    func rejectsMissingTitle() {
        #expect(throws: ConfigIssues.self) {
            try SnippetDefinition.parseAll(#"[[snippets]]\#nbody = "a""#)
        }
    }

    @Test("title の重複はエラー")
    func rejectsDuplicateTitle() {
        let toml = """
            [[snippets]]
            title = "now"
            body  = "a"

            [[snippets]]
            title = "now"
            body  = "b"
            """
        #expect(throws: ConfigIssues.self) { try SnippetDefinition.parseAll(toml) }
    }

    @Test("空の body_command はエラー")
    func rejectsEmptyCommand() {
        #expect(throws: ConfigIssues.self) {
            try SnippetDefinition.parseAll(
                #"[[snippets]]\#ntitle = "x"\#nbody_command = "  ""#)
        }
    }

    @Test("空の body は許す")
    func allowsEmptyText() throws {
        let snippets = try SnippetDefinition.parseAll(
            #"[[snippets]]\#ntitle = "x"\#nbody = """#)
        #expect(snippets == [SnippetDefinition(title: "x", body: .text(""))])
    }
}
