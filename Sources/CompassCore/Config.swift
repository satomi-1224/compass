import Foundation

/// `config.toml` の内容。
public struct Config: Equatable, Sendable {
    public var appearance: Appearance
    public var search: Search
    public var clipboard: Clipboard

    public init(
        appearance: Appearance = Appearance(),
        search: Search = Search(),
        clipboard: Clipboard = Clipboard()
    ) {
        self.appearance = appearance
        self.search = search
        self.clipboard = clipboard
    }
}

// MARK: - セクション

extension Config {

    public struct Appearance: Equatable, Sendable {
        /// 常にメインディスプレイに出す。マウス位置やフォーカスには追従しない
        /// （requirements.md 3.2）。
        public var display: DisplayTarget
        public var width: Double
        public var maxResults: Int

        public init(display: DisplayTarget = .main, width: Double = 680, maxResults: Int = 9) {
            self.display = display
            self.width = width
            self.maxResults = maxResults
        }
    }

    public enum DisplayTarget: String, Equatable, Sendable, CaseIterable {
        case main
    }

    public struct Search: Equatable, Sendable {
        public var matching: Matching
        public var files: FileSearch
        public var keywords: [Keyword]

        public init(
            matching: Matching = .fuzzy,
            files: FileSearch = FileSearch(),
            keywords: [Keyword] = Keyword.defaults
        ) {
            self.matching = matching
            self.files = files
            self.keywords = keywords
        }
    }

    /// fuzzy のみ。使用頻度による並び替えは行わない。同じ入力に同じ結果が返る
    /// 予測可能性を優先する（requirements.md 3.2）。
    public enum Matching: String, Equatable, Sendable, CaseIterable {
        case fuzzy
    }

    public struct FileSearch: Equatable, Sendable {
        /// Spotlight の探索範囲。`~` から始まるパスは展開して使う。
        public var scopes: [String]
        public var maxResults: Int

        public init(scopes: [String] = ["~"], maxResults: Int = 20) {
            self.scopes = scopes
            self.maxResults = maxResults
        }
    }

    /// 検索窓の先頭トークンでモードを切り替えるキーワード（requirements.md 3.2）。
    public struct Keyword: Equatable, Sendable {
        public var prefix: String
        public var kind: Kind
        /// `kind == .web` のとき必須。`{query}` を検索語で置き換える。
        public var url: String?

        public init(prefix: String, kind: Kind, url: String? = nil) {
            self.prefix = prefix
            self.kind = kind
            self.url = url
        }

        public enum Kind: String, Equatable, Sendable, CaseIterable {
            case file
            case web
        }

        /// 既定のキーワード。requirements.md 7.2 で想定していた組み合わせを確定させた。
        public static let defaults: [Keyword] = [
            Keyword(prefix: "f", kind: .file),
            Keyword(prefix: "g", kind: .web, url: "https://www.google.com/search?q={query}"),
            Keyword(prefix: "gh", kind: .web, url: "https://github.com/search?q={query}"),
        ]

        /// URL テンプレートに検索語を差し込む。
        public func resolvedURL(for query: String) -> URL? {
            guard let template = url else { return nil }
            // クエリ文字列に入るため、`&` や `=` まで含めて広くエスケープする。
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
            return URL(string: template.replacingOccurrences(of: "{query}", with: encoded))
        }
    }

    public struct Clipboard: Equatable, Sendable {
        /// false にすると監視ごと止める（requirements.md 3.4）。
        public var enabled: Bool
        public var maxItems: Int
        public var pollInterval: TimeInterval

        public init(enabled: Bool = true, maxItems: Int = 50, pollInterval: TimeInterval = 0.8) {
            self.enabled = enabled
            self.maxItems = maxItems
            self.pollInterval = pollInterval
        }
    }
}

// MARK: - パース

extension Config {

    /// `config.toml` を解釈する。
    ///
    /// **1 箇所の誤りで全体を捨てる。** 部分的に既定へ落とすと、直したつもりの設定が
    /// 効いていない状態に気づけない。呼び出し側は直前の正常な設定を保持する
    /// （requirements.md 5.4）。
    public static func parse(_ toml: String) throws -> Config {
        let raw: Raw
        do {
            raw = try tomlDecoder.decode(Raw.self, from: toml)
        } catch {
            throw ConfigIssues([ConfigIssue(file: .config, detail: "解釈できない: \(error)")])
        }

        var issues = IssueCollector(file: .config)
        var config = Config()

        if let appearance = raw.appearance {
            if let text = appearance.display {
                config.appearance.display =
                    issues.value(of: text, label: "[appearance] display", as: DisplayTarget.self)
                    ?? config.appearance.display
            }
            if let width = appearance.width {
                issues.require(width, in: 200...2000, label: "[appearance] width")
                config.appearance.width = width
            }
            if let maxResults = appearance.maxResults {
                issues.require(maxResults, in: 1...50, label: "[appearance] max_results")
                config.appearance.maxResults = maxResults
            }
        }

        if let search = raw.search {
            if let text = search.matching {
                config.search.matching =
                    issues.value(of: text, label: "[search] matching", as: Matching.self)
                    ?? config.search.matching
            }
            if let files = search.files {
                if let scopes = files.scopes {
                    if scopes.isEmpty {
                        issues.add("[search.files] scopes が空。探索範囲が無いと何も見つからない")
                    } else if let index = scopes.firstIndex(where: { $0.isEmpty }) {
                        // 値を出しても空文字で何も見えない。位置を伝える。
                        issues.add("[search.files] scopes の \(index + 1) 番目が空文字")
                    }
                    config.search.files.scopes = scopes
                }
                if let maxResults = files.maxResults {
                    issues.require(maxResults, in: 1...200, label: "[search.files] max_results")
                    config.search.files.maxResults = maxResults
                }
            }
            // 書かれていれば**置き換える**（既定へ追加はしない）。必要なものを全部書く。
            if let keywords = search.keywords {
                config.search.keywords = parseKeywords(keywords, &issues)
            }
        }

        if let clipboard = raw.clipboard {
            config.clipboard.enabled = clipboard.enabled ?? config.clipboard.enabled
            if let maxItems = clipboard.maxItems {
                issues.require(maxItems, in: 1...500, label: "[clipboard] max_items")
                config.clipboard.maxItems = maxItems
            }
            if let interval = clipboard.pollInterval {
                issues.require(interval, in: 0.1...10, label: "[clipboard] poll_interval")
                config.clipboard.pollInterval = interval
            }
        }

        try issues.throwIfNeeded()
        return config
    }

    private static func parseKeywords(
        _ items: [Raw.Search.Keyword], _ issues: inout IssueCollector
    ) -> [Keyword] {
        var result: [Keyword] = []
        var seen = Set<String>()

        for (index, item) in items.enumerated() {
            let label = "[[search.keywords]] #\(index + 1)"

            guard let prefix = item.prefix, !prefix.isEmpty else {
                issues.add("\(label) に prefix が無い")
                continue
            }
            // 先頭トークンで判定するため、空白を含む prefix は入力から切り出せない。
            guard !prefix.contains(where: \.isWhitespace) else {
                issues.add("\(label) prefix に空白は使えない: \(prefix)")
                continue
            }
            guard !seen.contains(prefix) else {
                issues.add("\(label) prefix が重複している: \(prefix)")
                continue
            }
            guard let kindText = item.kind else {
                issues.add("\(label) に kind が無い")
                continue
            }
            guard let kind = issues.value(of: kindText, label: "\(label) kind", as: Keyword.Kind.self)
            else { continue }

            switch kind {
            case .web:
                guard let url = item.url, !url.isEmpty else {
                    issues.add("\(label) kind = web には url が必要")
                    continue
                }
                guard url.contains("{query}") else {
                    issues.add("\(label) url に {query} が無い: \(url)")
                    continue
                }
            case .file:
                // 黙って無視すると、書いたつもりの url が効かない状態に気づけない。
                guard item.url == nil else {
                    issues.add("\(label) kind = file に url は書けない")
                    continue
                }
            }

            seen.insert(prefix)
            result.append(Keyword(prefix: prefix, kind: kind, url: item.url))
        }

        return result
    }

    /// TOML の生の形。全て Optional で受け、検証は `parse` が行う。
    fileprivate struct Raw: Decodable {
        var appearance: Appearance?
        var search: Search?
        var clipboard: Clipboard?

        struct Appearance: Decodable {
            var display: String?
            var width: Double?
            var maxResults: Int?
        }

        struct Search: Decodable {
            var matching: String?
            var files: Files?
            var keywords: [Keyword]?

            struct Files: Decodable {
                var scopes: [String]?
                var maxResults: Int?
            }

            struct Keyword: Decodable {
                var prefix: String?
                var kind: String?
                var url: String?
            }
        }

        struct Clipboard: Decodable {
            var enabled: Bool?
            var maxItems: Int?
            var pollInterval: Double?
        }
    }
}
