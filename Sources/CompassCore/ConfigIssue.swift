import Foundation
import TOMLDecoder

/// 設定ファイルは snake_case で書く（requirements.md 4章）ため、
/// Swift の命名へ変換しながら読む。
let tomlDecoder = TOMLDecoder(strategy: .init(key: .convertFromSnakeCase))

/// 設定ファイルの種類。
public enum ConfigFile: String, Sendable, CaseIterable, Equatable {
    case config = "config.toml"
    case hotkeys = "hotkeys.toml"
    case snippets = "snippets.toml"

    public var fileName: String { rawValue }
}

/// 設定の不備 1 件。
public struct ConfigIssue: Equatable, Sendable, CustomStringConvertible {
    public var file: ConfigFile
    public var detail: String

    public init(file: ConfigFile, detail: String) {
        self.file = file
        self.detail = detail
    }

    public var description: String { "\(file.fileName): \(detail)" }
}

/// 設定を採用できなかったときに投げる。
///
/// **見つかった不備をまとめて報告する。** 1 件直すたびに次が出るのでは、
/// 通知しか手がかりのない不可視常駐では原因を追いにくい。
public struct ConfigIssues: Error, Equatable, Sendable, CustomStringConvertible {
    public var items: [ConfigIssue]

    public init(_ items: [ConfigIssue]) {
        self.items = items
    }

    public var description: String {
        items.map(\.description).joined(separator: "\n")
    }
}

/// 検証中に不備を集める入れ物。
///
/// **範囲外や不明な値は丸めずにエラーにする。** 丸めると「設定したのに効いていない」
/// 状態になり、正常時に黙る設計では気づく手段がない。呼び出し側は直前の正常な設定を
/// 保持して動き続ける（requirements.md 5.4）。
struct IssueCollector {
    let file: ConfigFile
    private(set) var items: [ConfigIssue] = []

    init(file: ConfigFile) { self.file = file }

    var isEmpty: Bool { items.isEmpty }

    mutating func add(_ detail: String) {
        items.append(ConfigIssue(file: file, detail: detail))
    }

    /// 範囲を外れていれば記録する。**値は丸めない。**
    mutating func require<T: Comparable>(_ value: T, in range: ClosedRange<T>, label: String) {
        guard !range.contains(value) else { return }
        add("\(label) が範囲外: \(value)（有効範囲 \(range.lowerBound)〜\(range.upperBound)）")
    }

    /// 綴りから enum を引く。不明なら候補を添えて記録し nil を返す。
    mutating func value<E>(of text: String, label: String, as type: E.Type) -> E?
    where E: RawRepresentable & CaseIterable, E.RawValue == String {
        if let parsed = E(rawValue: text) { return parsed }
        let names = E.allCases.map(\.rawValue).joined(separator: " / ")
        add("\(label) の値が不明: \(text)（候補: \(names)）")
        return nil
    }

    func throwIfNeeded() throws {
        guard !items.isEmpty else { return }
        throw ConfigIssues(items)
    }
}
