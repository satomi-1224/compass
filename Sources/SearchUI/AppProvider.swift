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
    static let maxDepth = 2

    private let roots: [String]
    private let log: Log
    private var cache: [Candidate] = []

    public init(roots: [String] = AppProvider.defaultRoots, log: Log = .shared) {
        self.roots = roots
        self.log = log
    }

    /// 列挙できたアプリの数。
    public var count: Int { cache.count }

    /// 起動直後に一度呼んで、初回の表示を速くする。
    public func start() {
        refresh()
    }

    /// 走査し直す。**窓を開くたびに呼ぶ。**
    ///
    /// Spotlight の live update が使えないため、追加したアプリに追従する手段が
    /// これしかない。数百エントリの列挙なので体感できる遅さにはならない。
    public func refresh() {
        let scanned = scan()
        let changed = scanned.count != cache.count
        cache = scanned
        if changed {
            log.debug("アプリを列挙: \(cache.count) 件")
        }
    }

    /// キャッシュから絞り込む。同期で返る。
    public func candidates(matching text: String, limit: Int) -> [Candidate] {
        FuzzyMatcher.filter(cache, query: text, limit: limit)
    }

    // MARK: - 走査

    private func scan() -> [Candidate] {
        // キーは実体のパス。同じアプリを指すリンクが複数あっても 1 件にする。
        var found: [String: Candidate] = [:]
        var visited = Set<String>()
        for root in roots {
            collect(
                at: (root as NSString).expandingTildeInPath,
                depth: 0,
                visited: &visited,
                into: &found
            )
        }
        // 入力が空のときにそのまま出す順序。名前順にしておく。
        return found.values.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func collect(
        at path: String,
        depth: Int,
        visited: inout Set<String>,
        into found: inout [String: Candidate]
    ) {
        guard depth <= Self.maxDepth else { return }

        // **リンクは追う。** home-manager は `~/Applications/Home Manager Apps` を
        // nix store へのシンボリックリンクとして張るため、追わないと配置したアプリが
        // 1 つも拾えない（実際に mpv.app が漏れた）。
        //
        // 代わりに**実体のパスで訪問済みを覚える。** 同じ場所を二度見ないので、
        // 重複も循環も起きない。
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard visited.insert(resolved).inserted else { return }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return
        }

        for entry in entries {
            let child = "\(path)/\(entry)"

            if entry.hasSuffix(".app") {
                // Dock に出ないアプリは候補にしない。
                if Self.isBackgroundApp(child) { continue }
                // 実体で重複を判定し、開くのは見つけた経路のまま。
                let target = URL(fileURLWithPath: child).resolvingSymlinksInPath().path
                if found[target] == nil {
                    found[target] = Self.candidate(for: child)
                }
                // `.app` の中には入らない。内部のヘルパーアプリを拾わないため。
                continue
            }

            // リンク先がディレクトリなら下る（`fileExists` はリンクを追う）。
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { continue }

            collect(at: child, depth: depth + 1, visited: &visited, into: &found)
        }
    }

    /// Dock に出ないアプリか（`LSUIElement` / `LSBackgroundOnly`）。
    ///
    /// `/System/Library/CoreServices` にはユーザーが起動しないヘルパーが 100 以上
    /// あり、そのままだと候補の半分以上を占める（実測で 231 件のうち 133 件）。
    /// **ディレクトリごと外すと Finder まで落ちる**ため、Info.plist で判別する。
    ///
    /// `LSUIElement` は Bool でも文字列 `"1"` でも書けるので両方受ける。
    nonisolated static func isBackgroundApp(_ path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: "\(path)/Contents/Info.plist"),
            let info = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                as? [String: Any]
        else {
            // 読めないものは普通のアプリとして扱う。落とすと拾えるものが減るだけ。
            return false
        }
        return isTrue(info["LSUIElement"]) || isTrue(info["LSBackgroundOnly"])
    }

    private nonisolated static func isTrue(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool: bool
        case let number as NSNumber: number.boolValue
        case let string as String: string == "1" || string.lowercased() == "true"
        default: false
        }
    }

    /// アプリ 1 つを候補にする。
    ///
    /// 表示名は**ファイル名から `.app` を落としたもの**を使う。ローカライズされた
    /// 表示名（「システム設定」など）ではなく英名で揃えるのは、`FuzzyMatcher` が
    /// 見る文字列を 1 つに保つため。かな・日本語名での検索は未対応
    /// （requirements.md 7.2）。
    nonisolated static func candidate(for path: String) -> Candidate {
        let name = (path as NSString).lastPathComponent
        let title = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        return Candidate(
            id: path,
            title: title,
            subtitle: (path as NSString).abbreviatingWithTildeInPath,
            iconPath: path,
            action: .open(path: path)
        )
    }
}
