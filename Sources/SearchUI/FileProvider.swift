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

    private let log: Log
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
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

        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            completion([])
            return
        }

        let query = NSMetadataQuery()
        // **部分列マッチをワイルドカードで表現する。** Spotlight に fuzzy は無いので
        // `dcm` を `*d*c*m*` に開いて粗く集め、並べ替えは FuzzyMatcher に任せる。
        query.predicate = NSPredicate(
            format: "kMDItemFSName LIKE[cd] %@", Self.wildcardPattern(for: trimmed))
        query.searchScopes = scopes.map { ($0 as NSString).expandingTildeInPath }

        // **クロージャに query を捕まえない。** non-Sendable な値を @Sendable な
        // 通知ハンドラへ渡すと data race として弾かれる。self 経由で読む。
        self.query = query

        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let running = self.query else { return }
                let candidates = Self.candidates(from: running, matching: trimmed, limit: limit)
                self.cancel()
                self.warnIfIndexLooksDisabled(resultCount: candidates.count)
                completion(candidates)
            }
        }
        guard query.start() else {
            log.error("ファイル検索を開始できなかった: \(trimmed)")
            cancel()
            completion([])
            return
        }
    }

    public func cancel() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        if let query, query.isStarted {
            query.stop()
        }
        query = nil
    }

    /// 1 件も返らないのが続くなら、たいていインデックスが無い。
    ///
    /// 通知は出さない（requirements.md 5.4 の対象外）。手がかりをログに残すだけ。
    private func warnIfIndexLooksDisabled(resultCount: Int) {
        guard resultCount == 0, !warnedAboutEmptyResult else { return }
        warnedAboutEmptyResult = true
        log.warn(
            "ファイル検索が 0 件だった。Spotlight のインデックスが無効かもしれない"
                + "（`mdutil -s /` で確認、`sudo mdutil -i on /` で有効化）")
    }

    // MARK: - 変換

    /// `"dcm"` → `"*d*c*m*"`。
    ///
    /// Spotlight のパターンで意味を持つ `*` と `?` は落とす。残しても部分列の
    /// 意味にはならず、意図しない広がり方をする。
    nonisolated static func wildcardPattern(for text: String) -> String {
        var pattern = ""
        for character in text where character != "*" && character != "?" {
            pattern += "*\(character)"
        }
        return pattern.isEmpty ? "*" : pattern + "*"
    }

    private static func candidates(
        from query: NSMetadataQuery, matching text: String, limit: Int
    ) -> [Candidate] {
        query.disableUpdates()

        var found: [String: Candidate] = [:]
        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                let path = item.value(forAttribute: kMDItemPath as String) as? String
            else { continue }
            found[path] = Candidate(
                id: path,
                title: (path as NSString).lastPathComponent,
                subtitle: (path as NSString).abbreviatingWithTildeInPath,
                iconPath: path,
                action: .open(path: path)
            )
        }

        // Spotlight の並びは当てにできない。スコアで並べ直す。
        return FuzzyMatcher.filter(Array(found.values), query: text, limit: limit)
    }
}
