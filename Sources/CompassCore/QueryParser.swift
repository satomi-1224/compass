import Foundation

/// 検索窓の入力を「モード + クエリ」に分ける。
///
/// **先頭トークンで判定し、以降をそのモードのクエリとして扱う**（Alfred 方式。
/// requirements.md 3.2）。
///
/// ```
/// chr        → アプリ:   Google Chrome / Chromium
/// g swift    → Web:      Google で "swift" を検索
/// f report   → ファイル: ~/Documents/report.md
/// ```
///
/// **キーワードだけを打った時点ではモードに入らない。** 空白が続いて初めて切り替える。
/// `g` の時点で切り替えてしまうと、`g` で始まるアプリを探せなくなる。
public enum QueryParser {

    public enum Mode: Equatable, Sendable {
        case apps
        case files
        case web(Config.Keyword)
    }

    public struct Parsed: Equatable, Sendable {
        public var mode: Mode
        public var query: String

        public init(mode: Mode, query: String) {
            self.mode = mode
            self.query = query
        }
    }

    public static func parse(_ input: String, keywords: [Config.Keyword]) -> Parsed {
        // 空文字も要素として残す。`"g "` を 2 要素にしてモード切替を成立させる。
        let parts = input.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let keyword = keywords.first(where: { $0.prefix == parts[0] })
        else {
            return Parsed(mode: .apps, query: input)
        }

        let query = String(parts[1])
        switch keyword.kind {
        case .file:
            return Parsed(mode: .files, query: query)
        case .web:
            return Parsed(mode: .web(keyword), query: query)
        }
    }
}
