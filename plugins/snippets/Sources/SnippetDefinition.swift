import CompassCore
import Foundation
import TOMLDecoder

/// `plugins/snippets.toml` の 1 件。
public struct SnippetDefinition: Equatable, Sendable {
    public var title: String
    public var body: Body

    public init(title: String, body: Body) {
        self.title = title
        self.body = body
    }

    /// 中身の出どころ。**どちらか一方**で、両方は書けない。
    public enum Body: Equatable, Sendable {
        /// 静的テキスト。組み込みプレースホルダを含みうる。
        case text(String)
        /// 外部コマンドの出力。
        case command(String)
    }
}

extension SnippetDefinition {

    public static func parseAll(_ toml: String) throws -> [SnippetDefinition] {
        let raw: Raw
        do {
            let decoder = TOMLDecoder(strategy: .init(key: .convertFromSnakeCase))
            raw = try decoder.decode(Raw.self, from: toml)
        } catch {
            throw ConfigIssues([
                ConfigIssue(
                    file: SnippetPlugin.configurationFile,
                    detail: "解釈できない: \(error)"
                )
            ])
        }

        var issues = IssueCollector(file: SnippetPlugin.configurationFile)
        var result: [SnippetDefinition] = []
        var seen = Set<String>()

        for (index, item) in (raw.snippets ?? []).enumerated() {
            let label = "[[snippets]] #\(index + 1)"

            guard let title = item.title, !title.isEmpty else {
                issues.add("\(label) に title が無い")
                continue
            }
            guard !seen.contains(title) else {
                issues.add("\(label) title が重複している: \(title)")
                continue
            }

            let body: Body
            switch (item.body, item.bodyCommand) {
            case (let text?, nil):
                body = .text(text)
            case (nil, let command?):
                guard !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                    issues.add("\(label) \(title): body_command が空")
                    continue
                }
                body = .command(command)
            case (nil, nil):
                issues.add("\(label) \(title): body か body_command のどちらかが必要")
                continue
            case (_?, _?):
                issues.add("\(label) \(title): body と body_command は同時に書けない")
                continue
            }

            seen.insert(title)
            result.append(SnippetDefinition(title: title, body: body))
        }

        try issues.throwIfNeeded()
        return result
    }

    private struct Raw: Decodable {
        var snippets: [Item]?

        struct Item: Decodable {
            var title: String?
            var body: String?
            var bodyCommand: String?
        }
    }
}
