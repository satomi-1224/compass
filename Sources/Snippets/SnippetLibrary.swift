import CompassCore
import Foundation

/// スニペットを候補にする。
///
/// 一覧の見た目と選択は SearchUI を流用する（requirements.md 6章）。ここは
/// 「何を貼るか」を決めるだけ。
@MainActor
public final class SnippetLibrary {

    private let definitions: @MainActor () -> [SnippetDefinition]

    public init(definitions: @escaping @MainActor () -> [SnippetDefinition]) {
        self.definitions = definitions
    }

    /// 一覧に出す候補。
    ///
    /// `body` は**ここで展開する。** 一覧に「何が貼られるか」を出せるようにするため。
    /// `body_command` は**実行しない。** 一覧を開くだけで走ると、副作用のある
    /// コマンドを書いていた場合に選んでいないのに実行される。
    public func candidates(now: Date = Date()) -> [Candidate] {
        definitions().map { definition in
            switch definition.body {
            case .text(let text):
                let expanded = SnippetExpander.expand(text, now: now)
                return Candidate(
                    id: "snippet:\(definition.title)",
                    title: definition.title,
                    subtitle: TextSummary.line(of: expanded),
                    action: .paste(expanded)
                )
            case .command(let command):
                return Candidate(
                    id: "snippet:\(definition.title)",
                    title: definition.title,
                    subtitle: "$ \(TextSummary.line(of: command))",
                    action: .pasteCommandOutput(command)
                )
            }
        }
    }
}
