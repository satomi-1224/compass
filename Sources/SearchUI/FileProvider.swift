import CompassCore
import Foundation

/// Spotlight index からファイルを探す。
///
/// アプリと違って対象が広いのでキャッシュしない。入力ごとにクエリを投げ、
/// **新しい入力が来たら前のクエリを止める。** 止めないと古い結果が後から届いて
/// 一覧が入れ替わる。
///
/// > **Spotlight が無効なマシンでは常に 0 件になる。** アプリ列挙は自前走査に
/// > 切り替えたが、ホーム全体を対象にするファイル検索はインデックスなしでは
/// > 現実的でない。`mdutil -s /` が `Indexing disabled.` を返す環境では
/// > `sudo mdutil -i on /` で有効にする必要がある（requirements.md 7.5）。
@MainActor
public final class FileProvider {

    /// Spotlight から読み取る上限。
    ///
    /// 広いパターンはホーム配下の数万件に当たる。全件を候補へ変換してから
    /// 並べ替えるとメインスレッドが入力中に固まる。**打ち切ったことはログに残す。**
    nonisolated static let maxScanned = 2000

    /// ASCII でこれより短いクエリでは探さない。
    ///
    /// 1 文字だとパターンが `*a*` になってほとんどのファイルに当たる。絞り込めて
    /// いない結果を並べても選べないし、変換のコストだけが乗る。
    nonisolated static let minimumQueryLength = 2

    private let log: Log
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    /// クエリの世代。**`removeObserver` は既にキューへ載った通知を取り消せない**ため、
    /// これで古い通知を弾く。
    private var generation = 0
    /// インデックスが無いことに一度だけ気づけるようにする。毎回出すと煩い。
    private var warnedAboutEmptyResult = false

    public init(log: Log = .shared) {
        self.log = log
    }

    isolated deinit {
        cancel()
    }

    /// 探して、揃ったところで返す。
    ///
    /// - Parameters:
    ///   - scopes: 探索範囲。`~` から始まるパスは展開する。
    ///   - limit: 返す最大件数。
    public func search(
        _ text: String,
        scopes: [String],
        limit: Int,
        completion: @escaping @MainActor ([Candidate]) -> Void
    ) {
        cancel()

        // **パターン文字を落とした形で判断し、探し、並べ替える。**
        // 生の入力で長さを測ると `f **` が 2 文字として通り、`*` に開いて
        // 全ファイルに当たる。生の入力で並べ替えると、`*` がリテラルとして
        // 探されて結果が全部落ちる。
        let effective = Self.effectiveQuery(
            for: text.trimmingCharacters(in: .whitespaces))
        guard Self.isSearchable(effective) else {
            completion([])
            return
        }

        let query = NSMetadataQuery()
        // **部分列マッチをワイルドカードで表現する。** Spotlight に fuzzy は無いので
        // `dcm` を `*d*c*m*` に開いて粗く集め、並べ替えは FuzzyMatcher に任せる。
        query.predicate = NSPredicate(
            format: "kMDItemFSName LIKE[cd] %@", Self.wildcardPattern(for: effective))
        query.searchScopes = scopes.map { ($0 as NSString).expandingTildeInPath }
        // **並び順を決めておく。** 上限で切るとき順序が不定だと、同じ入力でも
        // 違う 2000 件を見ることになる。最近更新したものを優先すれば探している
        // ものが入る見込みが高く、切り取りも決定的になる。
        query.sortDescriptors = [
            NSSortDescriptor(key: kMDItemFSContentChangeDate as String, ascending: false)
        ]

        generation += 1
        let generation = self.generation

        // **クロージャに query を捕まえない。** non-Sendable な値を @Sendable な
        // 通知ハンドラへ渡すと data race として弾かれる。self 経由で読む。
        self.query = query

        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 世代が違えば、これは止めたはずのクエリの通知。**ここで弾かないと、
                // 走り始めたばかりの次のクエリを部分結果で確定させて止めてしまう。**
                guard self.generation == generation, let running = self.query else { return }

                let candidates = Self.candidates(
                    from: running, matching: effective, limit: limit, log: self.log)
                self.cancel()
                self.warnIfIndexLooksDisabled(resultCount: candidates.count)
                completion(candidates)
            }
        }

        guard query.start() else {
            log.error("ファイル検索を開始できなかった: \(effective)")
            cancel()
            completion([])
            return
        }
    }

    public func cancel() {
        // キューに残っている通知を無効にするため、世代を進める。
        generation += 1

        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        if let query, query.isStarted {
            query.stop()
        }
        query = nil
    }

    /// 1 件も返らないなら、たいていインデックスが無い。
    ///
    /// 通知は出さない（requirements.md 5.4 の対象外）。手がかりをログに残すだけ。
    private func warnIfIndexLooksDisabled(resultCount: Int) {
        guard resultCount == 0, !warnedAboutEmptyResult else { return }
        warnedAboutEmptyResult = true
        log.warn(
            "ファイル検索が 0 件だった。Spotlight のインデックスが無効かもしれない"
                + "（`mdutil -s /` で確認、`sudo mdutil -i on /` で有効化）")
    }

    // MARK: - クエリの整形

    /// パターンとして意味を持つ文字を落とした、実際に探す文字列。
    ///
    /// **Spotlight のパターンも fuzzy の並べ替えも、どちらもこれを使う。**
    /// 片方だけに使うと、探せているのに並べ替えで全部落ちる。
    nonisolated static func effectiveQuery(for text: String) -> String {
        String(text.filter { $0 != "*" && $0 != "?" })
    }

    /// 探すに足る長さか。`effectiveQuery` を通した文字列を渡す。
    ///
    /// ASCII の 1 文字は `*a*` になってほとんどのファイルに当たるが、
    /// **漢字やかなの 1 文字は十分に絞れる。** 文字種で分ける。
    nonisolated static func isSearchable(_ effective: String) -> Bool {
        guard !effective.isEmpty else { return false }
        if effective.count >= minimumQueryLength { return true }
        return effective.allSatisfy { !$0.isASCII }
    }

    /// `"dcm"` → `"*d*c*m*"`。`effectiveQuery` を通した文字列を渡す。
    nonisolated static func wildcardPattern(for effective: String) -> String {
        guard !effective.isEmpty else { return "*" }
        return effective.reduce(into: "") { $0 += "*\($1)" } + "*"
    }

    // MARK: - 変換

    private static func candidates(
        from query: NSMetadataQuery, matching text: String, limit: Int, log: Log
    ) -> [Candidate] {
        query.disableUpdates()

        let total = query.resultCount
        let scanned = min(total, maxScanned)
        var found: [String: Candidate] = [:]
        found.reserveCapacity(scanned)

        for index in 0..<scanned {
            guard let item = query.result(at: index) as? NSMetadataItem,
                let path = item.value(forAttribute: kMDItemPath as String) as? String
            else { continue }
            found[path] = Candidate(
                id: path,
                title: (path as NSString).lastPathComponent,
                subtitle: (path as NSString).abbreviatingWithTildeInPath,
                icon: .file(path: path),
                action: .open(path: path)
            )
        }

        if total > scanned {
            // 黙って切らない。**`debug` では既定のログレベルで出ないので `warn`。**
            log.warn(
                "ファイル検索が \(total) 件に当たった。最近更新した \(scanned) 件だけを見た"
                    + "（絞り込むと目的のものが入りやすくなる）")
        }

        // Spotlight の並びは当てにできない。スコアで並べ直す。
        return FuzzyMatcher.filter(Array(found.values), query: text, limit: limit)
    }
}
