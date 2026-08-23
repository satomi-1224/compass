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
        let needle = folded(query)
        guard !needle.isEmpty else { return Score(value: 0, positions: []) }

        let characters = Array(text)
        let lowered = folded(text)
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

    /// 候補 1 件に対するスコア。**title と aliases のうち最も良いものを採る。**
    ///
    /// 別名で当たった場合は title 側にマッチ位置が無いので、`positions` は
    /// 空になる（呼び出し側はハイライトを出さない）。
    public static func score(_ query: String, for candidate: Candidate) -> Score? {
        var best = score(query, in: candidate.title)
        for alias in candidate.aliases {
            guard let other = score(query, in: alias) else { continue }
            guard let current = best else {
                best = Score(value: other.value, positions: [])
                continue
            }
            if other.value > current.value {
                best = Score(value: other.value, positions: [])
            }
        }
        return best
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
            guard let score = score(query, for: candidate) else { return nil }
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

    // MARK: - 照合用の畳み込み

    /// 照合に使う形へ畳む。**1 文字は必ず 1 文字のまま。**
    ///
    /// 位置をそのままタイトルへ戻してハイライトに使うため、長さの変わる畳み方は
    /// できない（`String.lowercased()` は "İ" を 2 文字にする）。
    static func folded(_ text: String) -> [Character] {
        text.map(folded)
    }

    /// 1 文字を照合用に畳む。
    ///
    /// - 大文字小文字は区別しない
    /// - **全角の英数記号を半角に寄せる。** かな入力のまま打つと `ｃａｌ` になり、
    ///   そのままでは 1 件も出ない
    /// - **ひらがなをカタカナに寄せる。** 変換せずに確定した「かれんだー」で
    ///   「カレンダー」へ届く
    ///
    /// 半角カタカナ（`ｶﾞ`）は畳まない。濁点が独立した 1 文字なので、寄せると
    /// 文字数が変わってハイライトの位置がずれる。
    static func folded(_ character: Character) -> Character {
        var value = character
        if character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first {
            switch scalar.value {
            case 0xFF01...0xFF5E:
                // 全角の `！` 〜 `～`。半角とはちょうど 0xFEE0 ずれている。
                if let ascii = UnicodeScalar(scalar.value - 0xFEE0) { value = Character(ascii) }
            case 0x3000:
                value = " "
            case 0x3041...0x3096:
                // ひらがな → カタカナ。こちらもちょうど 0x60 ずれている。
                if let katakana = UnicodeScalar(scalar.value + 0x60) {
                    return Character(katakana)
                }
            default:
                break
            }
        }
        let lowered = value.lowercased()
        return lowered.count == 1 ? Character(lowered) : value
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
