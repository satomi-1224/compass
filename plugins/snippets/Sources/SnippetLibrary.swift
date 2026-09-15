import CompassCore
import Foundation

/// スニペット定義を、共通の検索 UI に渡せる候補へ変換する。
@MainActor
public final class SnippetLibrary {

    private let definitions: @MainActor () -> [SnippetDefinition]

    public init(definitions: @escaping @MainActor () -> [SnippetDefinition]) {
        self.definitions = definitions
    }

    /// `body` は表示時に展開するが、`body_command` は選ばれるまで実行しない。
    public func candidates(now: Date = Date()) -> [Candidate] {
        definitions().map { definition in
            switch definition.body {
            case .text(let text):
                let expanded = SnippetExpander.expand(text, now: now)
                return Candidate(
                    id: "snippet:\(definition.title)",
                    title: definition.title,
                    subtitle: TextSummary.line(of: expanded),
                    icon: .symbol("text.quote"),
                    action: .paste(expanded)
                )
            case .command(let command):
                return Candidate(
                    id: "snippet:\(definition.title)",
                    title: definition.title,
                    subtitle: "$ \(TextSummary.line(of: command))",
                    icon: .symbol("terminal"),
                    action: .pasteCommandOutput(command)
                )
            }
        }
    }
}
