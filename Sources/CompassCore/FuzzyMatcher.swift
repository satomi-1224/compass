import Foundation

/// 部分列マッチによる絞り込み。
///
/// **使用頻度による並び替えは行わない。** 同じ入力に常に同じ順序を返す予測可能性を
/// 優先する（requirements.md 3.2）。同点の候補は名前順で決めるため、辞書の
/// 列挙順や Spotlight の到着順に結果が左右されない。
public enum FuzzyMatcher {

    /// マッチの良さ。大きいほど良い。
    public struct Score: Equatable, Sendable {
        public var value: Int
        /// マッチした文字の位置。ハイライト表示に使う。
        public var positions: [Int]
    }

    /// `query` が `text` の部分列として現れるならスコアを返す。
    ///
    /// 大文字小文字は区別しない。`query` が空なら 0 点でマッチ扱いにする。
    public static func score(_ query: String, in text: String) -> Score? {
        let needle = Array(query.lowercased())
        guard !needle.isEmpty else { return Score(value: 0, positions: []) }

        let characters = Array(text)
        let lowered = Array(text.lowercased())
        guard needle.count <= characters.count else { return nil }

        var positions: [Int] = []
        var value = 0
        var needleIndex = 0
        var previousMatch: Int?

        for (index, character) in lowered.enumerated() {
            guard needleIndex < needle.count, character == needle[needleIndex] else { continue }

            var bonus = 1
            // 連続して並んでいれば強く加点する。"chr" が "Chrome" の頭に揃う形を優先。
            if let previous = previousMatch, previous == index - 1 {
                bonus += 8
            }
            // 単語の頭は探しているものである可能性が高い。
            if index == 0 {
                bonus += 12
            } else if isWordStart(at: index, in: characters) {
                bonus += 6
            }
            // 前方にあるほど良い。長い名前の末尾で拾うのは弱いマッチ。
            bonus += max(0, 4 - index / 4)

            value += bonus
            positions.append(index)
            previousMatch = index
            needleIndex += 1
        }

        guard needleIndex == needle.count else { return nil }
        // 同じ点なら短い候補を上に。"Chrome" と "Chromium" で前者を選べる。
        value -= characters.count / 8
        return Score(value: value, positions: positions)
    }

    /// 候補を絞り込んで並べる。
    ///
    /// - Parameter limit: 返す最大件数。
    public static func filter(
        _ candidates: [Candidate], query: String, limit: Int
    ) -> [Candidate] {
        guard limit > 0 else { return [] }
        guard !query.isEmpty else { return Array(candidates.prefix(limit)) }

        let scored = candidates.compactMap { candidate -> (candidate: Candidate, score: Score)? in
            guard let score = score(query, in: candidate.title) else { return nil }
            return (candidate, score)
        }

        return scored
            .sorted { left, right in
                if left.score.value != right.score.value {
                    return left.score.value > right.score.value
                }
                // **同点は名前順で決める。** 到着順に依存させると同じ入力で並びが変わる。
                let byTitle = left.candidate.title.localizedStandardCompare(
                    right.candidate.title)
                if byTitle != .orderedSame {
                    return byTitle == .orderedAscending
                }
                // **同名なら id（パス）で決める。** `sorted(by:)` は安定と保証されて
                // いないうえ、入力は辞書の値なのでハッシュシードで並びが変わる。
                // `README.md` が複数あるとき、どれが limit に残るかが実行ごとに
                // 変わってしまう。
                return left.candidate.id < right.candidate.id
            }
            .prefix(limit)
            .map(\.candidate)
    }

    /// 単語の切れ目の直後か。
    private static func isWordStart(at index: Int, in characters: [Character]) -> Bool {
        let previous = characters[index - 1]
        if previous.isWhitespace || previous == "-" || previous == "_" || previous == "."
            || previous == "/"
        {
            return true
        }

        let current = characters[index]
        guard current.isUppercase else { return false }
        // camelCase の境目。"vsCode" の C。
        if previous.isLowercase { return true }
        // 頭字語の終わり。**大文字が続いたあとに小文字が来る位置が次の語の頭。**
        // "VSCode" の C や "HTTPServer" の S がこれで拾える。前の文字だけを見ると
        // どちらも大文字なので境目に見えない。
        if index + 1 < characters.count, characters[index + 1].isLowercase { return true }
        return false
    }
}
