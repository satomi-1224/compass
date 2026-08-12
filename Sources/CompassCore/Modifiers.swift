import Foundation

/// トリガーの修飾キー。
///
/// アプリ全体で 1 種類だけ定義し、その配下に全てのキーを並べる
/// （requirements.md 3.1）。Carbon のビットマスクへの変換は HotkeyEngine が
/// 受け持ち、ここでは設定ファイルの語彙との対応だけを持つ。
public struct Modifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt

    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let command = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let shift = Modifiers(rawValue: 1 << 2)
    public static let control = Modifiers(rawValue: 1 << 3)

    /// 設定に書ける綴り。`cmd` と `command` のような別名を許す。
    private static let spellings: [(String, Modifiers)] = [
        ("cmd", .command), ("command", .command),
        ("alt", .option), ("opt", .option), ("option", .option),
        ("shift", .shift),
        ("ctrl", .control), ("control", .control),
    ]

    /// 綴りの候補。エラーメッセージに使う。
    public static var allSpellings: [String] { spellings.map(\.0) }

    /// `"cmd+alt+shift"` を解釈する。
    ///
    /// 綴りが不明なものが 1 つでもあれば nil を返す。部分的に解釈して動かすと、
    /// 意図と違う組み合わせで登録されて原因が分からなくなる。
    public static func parse(_ text: String) -> Modifiers? {
        let tokens = text
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        var result = Modifiers()
        for token in tokens {
            guard let match = spellings.first(where: { $0.0 == token })?.1 else { return nil }
            result.insert(match)
        }
        return result
    }

    /// 表示用。`⌃⌥⇧⌘` の順に並べる（macOS の慣例）。
    public var symbols: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}
