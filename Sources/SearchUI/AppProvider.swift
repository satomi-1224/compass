import AppKit
import CompassCore
import Foundation

/// インストールされているアプリを列挙して保持する。
///
/// **Spotlight は使わない。** このマシンでは `mdutil -s /` が `Indexing disabled.` を
/// 返し、`NSMetadataQuery` も `mdfind` も 1 件も返さなかった（実測）。
/// インデックスの有無に依存しない自前の走査にしてある（requirements.md 3.2）。
///
/// 既知のアプリ置き場だけを浅く下り、**`.app` の中には入らない。** 多くのアプリは
/// 内部にヘルパーや更新ツールを `.app` として抱えていて、拾うと候補が埋まる。
///
/// 現行 `search.lua` は `~/Applications` の直下しか走査しておらず、
/// `~/Applications/Chrome Apps.localized/` 配下の PWA（Claude.app, Remap.app）を
/// 拾えていなかった。2 階層まで下ることでこれも拾える。
@MainActor
public final class AppProvider {

    /// 走査するアプリ置き場。
    public static let defaultRoots = [
        "/Applications",
        "/System/Applications",
        "/System/Library/CoreServices",
        "~/Applications",
    ]

    /// 各ルートから何階層下るか。`/Applications/Utilities/…` と
    /// `~/Applications/Chrome Apps.localized/…` に届く深さ。
    nonisolated static let maxDepth = 2

    /// 走査が終わって一覧が入れ替わった。**表示中なら絞り込み直す。**
    ///
    /// 走査はバックグラウンドで走るので、窓を開いた直後に打った文字は古い一覧に
    /// 当たることがある。終わったら知らせて、同じ入力で引き直させる。
    public var onRefresh: (@MainActor () -> Void)?

    private let roots: [String]
    private let log: Log
    private var cache: [Candidate] = []
    /// パスごとに一度だけ読んだ結果。**窓を開くたびに読み直さない。**
    ///
    /// `.app` 1 つにつき Info.plist と `InfoPlist.loctable` を読む。実測で
    /// 169 件の初回走査に 150ms かかる。ホットキーを押してから窓が出るまでに
    /// 毎回挟まると体感できる。
    private var metadata: [String: Metadata] = [:]
    private var isScanning = false

    public init(roots: [String] = AppProvider.defaultRoots, log: Log = .shared) {
        self.roots = roots
        self.log = log
    }

    /// 列挙できたアプリの数。
    public var count: Int { cache.count }

    /// 起動直後に一度呼ぶ。**同期で走査して、最初のホットキーに間に合わせる。**
    public func start() {
        apply(Self.scan(roots: roots, metadata: metadata, log: log))
    }

    /// 走査し直す。**窓を開くたびに呼ぶ。**
    ///
    /// Spotlight の live update が使えないため、追加したアプリに追従する手段が
    /// これしかない。ただし**走査はバックグラウンドに逃がす。** 窓は候補ゼロで
    /// 先に出せるので、待たせる理由がない。終わったら `onRefresh` で知らせる。
    public func refresh() {
        // 走査中に重ねて呼ばない。窓の開閉を繰り返しても積み上がらない。
        guard !isScanning else { return }
        isScanning = true

        let roots = self.roots
        let known = self.metadata
        let log = self.log
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.scan(roots: roots, metadata: known, log: log)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isScanning = false
                    let changed = self.apply(result)
                    if changed { self.onRefresh?() }
                }
            }
        }
    }

    /// 走査結果を取り込む。
    ///
    /// - Returns: 一覧が変わったか。
    @discardableResult
    private func apply(_ result: ScanResult) -> Bool {
        metadata = result.metadata
        guard cache != result.candidates else { return false }
        cache = result.candidates
        log.debug("アプリを列挙: \(cache.count) 件")
        return true
    }

    /// キャッシュから絞り込む。同期で返る。
    public func candidates(matching text: String, limit: Int) -> [Candidate] {
        FuzzyMatcher.filter(cache, query: text, limit: limit)
    }

    /// プラグインコマンドとまとめて順位付けするための全候補。
    var allCandidates: [Candidate] { cache }

    // MARK: - 走査

    /// `.app` 1 つぶんの、読み直したくない情報。
    struct Metadata: Sendable, Equatable {
        /// 候補から外すか。
        var hidden: Bool
        /// Finder と同じ表示名。
        var title: String
        /// ファイル名から `.app` を落としたもの。`title` と同じなら nil。
        var alias: String?
    }

    struct ScanResult: Sendable {
        var candidates: [Candidate]
        var metadata: [String: Metadata]
    }

    /// **MainActor の外から呼ぶ。** 触るのは引数だけで、状態を持たない。
    nonisolated static func scan(
        roots: [String], metadata: [String: Metadata], log: Log
    ) -> ScanResult {
        var context = ScanContext(
            metadata: metadata, languages: languageCandidates(from: Locale.preferredLanguages))

        for root in roots {
            collect(at: (root as NSString).expandingTildeInPath, depth: 0, into: &context)
        }

        // 入力が空のときにそのまま出す順序。名前順にしておく。
        let candidates = context.found.values.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        return ScanResult(candidates: candidates, metadata: context.metadata)
    }

    /// 走査中に持ち回る状態。
    private struct ScanContext {
        /// キーは実体のパス。同じアプリを指すリンクが複数あっても 1 件にする。
        var found: [String: Candidate] = [:]
        var visited = Set<String>()
        var metadata: [String: Metadata]
        let languages: [String]
    }

    private nonisolated static func collect(
        at path: String, depth: Int, into context: inout ScanContext
    ) {
        guard depth <= maxDepth else { return }

        // **リンクは追う。** home-manager は `~/Applications/Home Manager Apps` を
        // nix store へのシンボリックリンクとして張るため、追わないと配置したアプリが
        // 1 つも拾えない（実際に mpv.app が漏れた）。
        //
        // 代わりに**実体のパスで訪問済みを覚える。** 同じ場所を二度見ないので、
        // 重複も循環も起きない。
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard context.visited.insert(resolved).inserted else { return }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return
        }

        for entry in entries {
            let child = "\(path)/\(entry)"

            if entry.hasSuffix(".app") {
                // 実体で重複を判定し、開くのは見つけた経路のまま。
                let target = URL(fileURLWithPath: child).resolvingSymlinksInPath().path
                // **重複を先に弾く。** 同じ実体へのリンクが複数あると、
                // 後の Info.plist 読み込みを何度も繰り返すことになる。
                if context.found[target] == nil {
                    let info = metadata(for: child, in: &context)
                    if !info.hidden {
                        context.found[target] = candidate(for: child, metadata: info)
                    }
                }
                // `.app` の中には入らない。内部のヘルパーアプリを拾わないため。
                continue
            }

            // リンク先がディレクトリなら下る（`fileExists` はリンクを追う）。
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { continue }

            collect(at: child, depth: depth + 1, into: &context)
        }
    }

    private nonisolated static func metadata(
        for path: String, in context: inout ScanContext
    ) -> Metadata {
        if let cached = context.metadata[path] { return cached }
        let info = readMetadata(for: path, languages: context.languages)
        context.metadata[path] = info
        return info
    }

    /// `.app` を 1 つ読む。**ここだけがディスクに触る。**
    nonisolated static func readMetadata(for path: String, languages: [String]) -> Metadata {
        let name = (path as NSString).lastPathComponent
        let base = name.hasSuffix(".app") ? String(name.dropLast(4)) : name

        var uiElement = false
        var backgroundOnly = false
        if let data = FileManager.default.contents(atPath: "\(path)/Contents/Info.plist"),
            let info = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                as? [String: Any]
        {
            uiElement = isTrue(info["LSUIElement"])
            backgroundOnly = isTrue(info["LSBackgroundOnly"])
        }
        // 読めないものは普通のアプリとして扱う。外すと拾えるものが減るだけ。

        let hidden = isHidden(path: path, uiElement: uiElement, backgroundOnly: backgroundOnly)
        // 隠すと決めたなら表示名は要らない。**loctable を読まずに済ませる。**
        guard !hidden else { return Metadata(hidden: true, title: base, alias: nil) }

        let localized = localizedName(for: path, languages: languages)
        guard let localized, localized != base else {
            return Metadata(hidden: false, title: base, alias: nil)
        }
        return Metadata(hidden: false, title: localized, alias: base)
    }

    /// `LSUIElement` を理由に外すのはこの下だけ。
    nonisolated static let systemCoreServices = "/System/Library/CoreServices/"

    /// 候補から外すか。パスと 2 つのフラグだけで決める。
    ///
    /// - `LSBackgroundOnly` は**UI を持たない。** 起動しても何も起きないので常に外す
    /// - `LSUIElement` は**メニューバーだけのアプリ。** Docker や Hammerspoon が
    ///   これに当たり、**ランチャーが最も役立つ相手なので落としてはいけない。**
    ///   ただし `/System/Library/CoreServices` 直下にはユーザーが起動しない
    ///   ヘルパーが 100 以上あって候補を埋めるので、そこに限って外す
    ///
    /// Finder は同じ `CoreServices` にあるが `LSUIElement` を持たないので残る。
    nonisolated static func isHidden(
        path: String, uiElement: Bool, backgroundOnly: Bool
    ) -> Bool {
        if backgroundOnly { return true }
        guard uiElement else { return false }
        return path.hasPrefix(systemCoreServices)
    }

    /// plist の真偽値。**`YES` を忘れてはいけない。** 実際の CoreServices の
    /// バンドルは `<string>YES</string>` で書いている（AddPrinter, PIPAgent）。
    private nonisolated static func isTrue(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool: bool
        case let number as NSNumber: number.boolValue
        case let string as String: ["1", "true", "yes"].contains(string.lowercased())
        default: false
        }
    }

    // MARK: - 表示名

    /// 引く言語の順。`ja-JP` は `ja` にも落として探す。
    ///
    /// `zh-Hans-CN` のように 3 つ以上あっても、後ろから 1 つずつ落として全て試す。
    nonisolated static func languageCandidates(from preferred: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for tag in preferred {
            var parts = tag.split(separator: "-").map(String.init)
            while !parts.isEmpty {
                let candidate = parts.joined(separator: "-")
                if seen.insert(candidate).inserted { result.append(candidate) }
                parts.removeLast()
            }
        }
        return result
    }

    /// Finder と同じ表示名。見つからなければ nil。
    ///
    /// **`FileManager.displayName` では足りない。** macOS 13 以降のシステムアプリは
    /// 各言語の名前を `.lproj/InfoPlist.strings` ではなく
    /// `Contents/Resources/InfoPlist.loctable` に 1 つへまとめて持っていて、
    /// Foundation の表示名 API はこれを読まない。実測では 169 件中 91 件
    /// （「システム設定」「計算機」「メモ」など）が英名のままになり、**日本語で
    /// 打つと 1 件も出なかった。**
    nonisolated static func localizedName(for path: String, languages: [String]) -> String? {
        let resources = "\(path)/Contents/Resources"
        if let name = name(fromLoctable: "\(resources)/InfoPlist.loctable", languages: languages) {
            return name
        }
        // 古い形式（言語ごとの .strings）。第三者アプリはこちらが多い。
        for language in languages {
            if let name = name(fromStrings: "\(resources)/\(language).lproj/InfoPlist.strings") {
                return name
            }
        }
        return nil
    }

    private nonisolated static func name(fromLoctable path: String, languages: [String]) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
            let table = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                as? [String: [String: Any]]
        else { return nil }
        for language in languages {
            guard let entry = table[language], let name = displayName(in: entry) else { continue }
            return name
        }
        return nil
    }

    private nonisolated static func name(fromStrings path: String) -> String? {
        // **`NSDictionary(contentsOfFile:)` を使う。** `.strings` はバイナリ plist の
        // ことも旧形式のテキストのこともあり、両方を読めるのはこれだけ。
        guard let entry = NSDictionary(contentsOfFile: path) as? [String: Any] else { return nil }
        return displayName(in: entry)
    }

    /// `CFBundleDisplayName` を優先する。Finder が使う順序に合わせる。
    private nonisolated static func displayName(in entry: [String: Any]) -> String? {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            guard let name = entry[key] as? String, !name.isEmpty else { continue }
            return name
        }
        return nil
    }

    /// アプリ 1 つを候補にする。
    ///
    /// **表示名は Finder と同じものを使う。** 「システム設定」を「システム設定」と
    /// 打って見つけられないと、ランチャーとして成立しない。英名（`System Settings`）は
    /// `aliases` に入れてあるので、どちらで打っても当たる。
    nonisolated static func candidate(for path: String, metadata: Metadata) -> Candidate {
        Candidate(
            id: path,
            title: metadata.title,
            subtitle: (path as NSString).abbreviatingWithTildeInPath,
            icon: .file(path: path),
            action: .open(path: path),
            aliases: metadata.alias.map { [$0] } ?? []
        )
    }
}
