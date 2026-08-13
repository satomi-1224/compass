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

    private func writePlist(_ dictionary: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: url)
    }

    /// **メニューバーだけのアプリは落としてはいけない。** Docker や Hammerspoon が
    /// これに当たり、ランチャーが最も役立つ相手。「Dock に出ない」は
    /// 「ユーザーが起動しない」ではない。
    @Test("メニューバーだけのアプリは残す")
    func keepsMenuBarApps() {
        for path in [
            "/Applications/Docker.app",
            "/Applications/Hammerspoon.app",
            "/Users/x/Applications/comet.app",
        ] {
            #expect(
                AppProvider.isHidden(path: path, uiElement: true, backgroundOnly: false) == false,
                "\(path) を落としてはいけない")
        }
    }

    /// `/System/Library/CoreServices` にはユーザーが起動しないヘルパーが 100 以上
    /// あり、そのままだと候補の半分以上を占める（実測で 231 件のうち 133 件）。
    @Test("CoreServices 直下のメニューバーアプリだけ除く")
    func excludesCoreServicesHelpers() {
        #expect(
            AppProvider.isHidden(
                path: "/System/Library/CoreServices/AddPrinter.app",
                uiElement: true, backgroundOnly: false))
        #expect(
            AppProvider.isHidden(
                path: "/System/Library/CoreServices/PIPAgent.app",
                uiElement: true, backgroundOnly: false))
    }

    /// Finder は CoreServices にあるが `LSUIElement` を持たない。
    /// **ディレクトリごと外すと落ちてしまう**ので、フラグで判別している。
    @Test("Finder は CoreServices にあっても残る")
    func keepsFinder() {
        #expect(
            AppProvider.isHidden(
                path: "/System/Library/CoreServices/Finder.app",
                uiElement: false, backgroundOnly: false) == false)
    }

    /// UI を持たないので、起動しても何も起きない。どこにあっても外す。
    @Test("LSBackgroundOnly はどこにあっても除く")
    func excludesBackgroundOnly() {
        #expect(
            AppProvider.isHidden(
                path: "/Applications/Daemon.app", uiElement: false, backgroundOnly: true))
    }

    /// **実際の CoreServices は `<string>YES</string>` で書いている。**
    /// `"1"` と `"true"` しか見ていないと、狙った相手が残ってしまう。
    @Test("YES / true / 1 を真として読む")
    func readsBooleanForms() throws {
        let base = try makeTree([
            "Yes.app/Contents", "True.app/Contents", "One.app/Contents", "No.app/Contents",
        ])
        defer { try? FileManager.default.removeItem(at: base) }

        try writePlist(
            ["LSBackgroundOnly": "YES"],
            to: base.appendingPathComponent("Yes.app/Contents/Info.plist"))
        try writePlist(
            ["LSBackgroundOnly": true],
            to: base.appendingPathComponent("True.app/Contents/Info.plist"))
        try writePlist(
            ["LSBackgroundOnly": "1"],
            to: base.appendingPathComponent("One.app/Contents/Info.plist"))
        try writePlist(
            ["LSBackgroundOnly": "NO"],
            to: base.appendingPathComponent("No.app/Contents/Info.plist"))

        #expect(AppProvider.isHidden(base.appendingPathComponent("Yes.app").path))
        #expect(AppProvider.isHidden(base.appendingPathComponent("True.app").path))
        #expect(AppProvider.isHidden(base.appendingPathComponent("One.app").path))
        #expect(AppProvider.isHidden(base.appendingPathComponent("No.app").path) == false)
    }

    @Test("走査でも LSBackgroundOnly を除く")
    func scanExcludesBackgroundOnly() throws {
        let base = try makeTree(["Normal.app/Contents", "Daemon.app/Contents"])
        defer { try? FileManager.default.removeItem(at: base) }

        try writePlist(
            ["LSBackgroundOnly": true],
            to: base.appendingPathComponent("Daemon.app/Contents/Info.plist"))
        try writePlist(
            ["CFBundleName": "Normal"],
            to: base.appendingPathComponent("Normal.app/Contents/Info.plist"))

        let provider = AppProvider(roots: [base.path])
        provider.refresh()

        #expect(provider.count == 1)
        #expect(provider.candidates(matching: "", limit: 9).map(\.title) == ["Normal"])
    }

    /// 落とすと拾えるものが減るだけなので、読めないときは普通のアプリとして扱う。
    @Test("Info.plist が無ければ普通のアプリとして扱う")
    func treatsMissingPlistAsNormal() throws {
        let base = try makeTree(["NoPlist.app"])
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(AppProvider.isHidden(base.appendingPathComponent("NoPlist.app").path) == false)
    }

    @Test("`.app` を落とした名前を表示する")
    func stripsAppExtension() {
        let candidate = AppProvider.candidate(for: "/Applications/Google Chrome.app")
        #expect(candidate.title == "Google Chrome")
        #expect(candidate.action == .open(path: "/Applications/Google Chrome.app"))
        #expect(candidate.icon == .file(path: "/Applications/Google Chrome.app"))
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

    /// **Spotlight のパターンと fuzzy の並べ替えは同じ文字列を使う。** 片方だけに
    /// 適用すると、探せているのに `*` がリテラルとして扱われて全件落ちる。
    @Test("パターン文字は探す前に落とす")
    func stripsPatternCharacters() {
        #expect(FileProvider.effectiveQuery(for: "a*b") == "ab")
        #expect(FileProvider.effectiveQuery(for: "a?b") == "ab")
        #expect(FileProvider.effectiveQuery(for: "dcm") == "dcm")
        #expect(FileProvider.effectiveQuery(for: "**") == "")
    }

    /// `f **` は 2 文字だが、開くと `*` になって全ファイルに当たる。
    /// **長さは落とした後の文字列で測る。**
    @Test("パターン文字だけのクエリでは探さない")
    func rejectsPatternOnlyQuery() {
        #expect(FileProvider.isSearchable(FileProvider.effectiveQuery(for: "**")) == false)
        #expect(FileProvider.isSearchable(FileProvider.effectiveQuery(for: "*a")) == false)
        #expect(FileProvider.isSearchable(FileProvider.effectiveQuery(for: "*ab")))
    }

    /// ASCII 1 文字は広すぎるが、**漢字やかなの 1 文字は十分に絞れる。**
    /// 一律で 2 文字にすると `f 本` が引けなくなる。
    @Test("非 ASCII なら 1 文字でも探す")
    func allowsSingleNonASCII() {
        #expect(FileProvider.isSearchable("a") == false)
        #expect(FileProvider.isSearchable("ab"))
        #expect(FileProvider.isSearchable("本"))
        #expect(FileProvider.isSearchable("あ"))
        #expect(FileProvider.isSearchable("") == false)
    }

    @MainActor
    @Test("探せないクエリではその場で空を返す")
    func skipsUnsearchableQuery() {
        let provider = FileProvider()
        var results: [[Candidate]] = []

        for text in ["a", " ", "", "**", "*a"] {
            provider.search(text, scopes: ["~"], limit: 9) { results.append($0) }
        }

        // クエリを投げていないので同期で返る。
        let allEmpty = results.allSatisfy { $0.isEmpty }
        #expect(results.count == 5)
        #expect(allEmpty)
        provider.cancel()
    }

    @Test("読み取り上限が入っている")
    func hasScanLimit() {
        #expect(FileProvider.maxScanned > 0)
        #expect(FileProvider.minimumQueryLength >= 2)
    }
}
