import CompassCore
import Foundation
import Testing

@testable import SearchUI

@MainActor
@Suite("AppProvider")
struct AppProviderTests {

    /// 走査対象を作る。`.app` はディレクトリとして置く（実体は問わない）。
    private func makeTree(_ paths: [String]) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("compass-apps-\(UUID().uuidString)", isDirectory: true)
        for path in paths {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent(path, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return base
    }

    @Test("直下の .app を拾う")
    func findsTopLevelApps() throws {
        let base = try makeTree(["Safari.app", "Mail.app"])
        defer { try? FileManager.default.removeItem(at: base) }

        let provider = AppProvider(roots: [base.path])
        provider.refresh()

        #expect(provider.count == 2)
        #expect(provider.candidates(matching: "saf", limit: 9).map(\.title) == ["Safari"])
    }

    /// `/Applications/Utilities/…` と `~/Applications/Chrome Apps.localized/…` に届く深さ。
    @Test("2 階層下の .app も拾う")
    func findsNestedDirectories() throws {
        let base = try makeTree([
            "Utilities/Terminal.app",
            "Chrome Apps.localized/Claude.app",
        ])
        defer { try? FileManager.default.removeItem(at: base) }

        let provider = AppProvider(roots: [base.path])
        provider.refresh()

        #expect(provider.count == 2)
        #expect(provider.candidates(matching: "claude", limit: 9).count == 1)
    }

    /// 多くのアプリは内部にヘルパーや更新ツールを `.app` として抱えている。
    /// 拾うと候補が埋まって選べなくなる。
    @Test("`.app` の中には入らない")
    func doesNotDescendIntoBundles() throws {
        let base = try makeTree(["Foo.app/Contents/Library/Helper.app"])
        defer { try? FileManager.default.removeItem(at: base) }

        let provider = AppProvider(roots: [base.path])
        provider.refresh()

        #expect(provider.count == 1)
        #expect(provider.candidates(matching: "helper", limit: 9).isEmpty)
    }

    /// home-manager は `~/Applications/Home Manager Apps` を nix store への
    /// シンボリックリンクとして張る。追わないと配置したアプリが 1 つも拾えない。
    @Test("シンボリックリンクのディレクトリを追う")
    func followsSymlinkedDirectories() throws {
        let base = try makeTree(["store/mpv.app", "Applications"])
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("Applications/Home Manager Apps"),
            withDestinationURL: base.appendingPathComponent("store")
        )

        let provider = AppProvider(roots: [base.appendingPathComponent("Applications").path])
        provider.refresh()

        #expect(provider.candidates(matching: "mpv", limit: 9).count == 1)
    }

    /// 実体で重複を判定する。同じアプリを指すリンクが複数あっても 1 件。
    @Test("同じアプリを二度出さない")
    func deduplicatesByRealPath() throws {
        let base = try makeTree(["store/mpv.app", "Applications"])
        defer { try? FileManager.default.removeItem(at: base) }
        for name in ["link-a", "link-b"] {
            try FileManager.default.createSymbolicLink(
                at: base.appendingPathComponent("Applications/\(name)"),
                withDestinationURL: base.appendingPathComponent("store")
            )
        }

        let provider = AppProvider(roots: [base.appendingPathComponent("Applications").path])
        provider.refresh()

        #expect(provider.candidates(matching: "mpv", limit: 9).count == 1)
    }

    /// リンクが自分の親を指していても、訪問済みの記録で止まる。
    @Test("循環するリンクで止まる")
    func stopsOnCycle() throws {
        let base = try makeTree(["Applications"])
        defer { try? FileManager.default.removeItem(at: base) }
        let apps = base.appendingPathComponent("Applications")
        try FileManager.default.createSymbolicLink(at: apps.appendingPathComponent("self"), withDestinationURL: apps)

        let provider = AppProvider(roots: [apps.path])
        provider.refresh()

        #expect(provider.count == 0)
    }

    @Test("深すぎる階層は見ない")
    func stopsAtMaxDepth() throws {
        let base = try makeTree(["a/b/c/TooDeep.app"])
        defer { try? FileManager.default.removeItem(at: base) }

        let provider = AppProvider(roots: [base.path])
        provider.refresh()

        #expect(provider.count == 0)
    }

    @Test("無いディレクトリを渡しても落ちない")
    func toleratesMissingRoots() {
        let provider = AppProvider(roots: ["/nonexistent-\(UUID().uuidString)"])
        provider.refresh()
        #expect(provider.count == 0)
    }

    @Test("`.app` を落とした名前を表示する")
    func stripsAppExtension() {
        let candidate = AppProvider.candidate(for: "/Applications/Google Chrome.app")
        #expect(candidate.title == "Google Chrome")
        #expect(candidate.action == .open(path: "/Applications/Google Chrome.app"))
        #expect(candidate.iconPath == "/Applications/Google Chrome.app")
    }
}

@Suite("FileProvider")
struct FileProviderTests {

    /// Spotlight に fuzzy は無い。部分列をワイルドカードに開いて粗く集める。
    @Test("部分列をワイルドカードに開く")
    func buildsWildcardPattern() {
        #expect(FileProvider.wildcardPattern(for: "dcm") == "*d*c*m*")
        #expect(FileProvider.wildcardPattern(for: "a") == "*a*")
    }

    /// `*` と `?` を残すと部分列の意味にならず、意図しない広がり方をする。
    @Test("パターン文字は落とす")
    func stripsPatternCharacters() {
        #expect(FileProvider.wildcardPattern(for: "a*b") == "*a*b*")
        #expect(FileProvider.wildcardPattern(for: "a?b") == "*a*b*")
    }

    @Test("パターン文字だけなら全件パターンになる")
    func patternOnlyBecomesWildcard() {
        #expect(FileProvider.wildcardPattern(for: "*") == "*")
        #expect(FileProvider.wildcardPattern(for: "") == "*")
    }

    /// 1 文字だとパターンが `*a*` になってほとんどのファイルに当たる。絞り込めて
    /// いない数万件を候補へ変換すると、入力中にメインスレッドが固まる。
    @MainActor
    @Test("短すぎるクエリでは探さず、その場で空を返す")
    func skipsShortQuery() {
        let provider = FileProvider()
        var results: [[Candidate]] = []

        provider.search("a", scopes: ["~"], limit: 9) { results.append($0) }
        provider.search(" ", scopes: ["~"], limit: 9) { results.append($0) }
        provider.search("", scopes: ["~"], limit: 9) { results.append($0) }

        // クエリを投げていないので同期で返る。
        let allEmpty = results.allSatisfy { $0.isEmpty }
        #expect(results.count == 3)
        #expect(allEmpty)
        provider.cancel()
    }

    @Test("読み取り上限が入っている")
    func hasScanLimit() {
        #expect(FileProvider.maxScanned > 0)
        #expect(FileProvider.minimumQueryLength >= 2)
    }
}
