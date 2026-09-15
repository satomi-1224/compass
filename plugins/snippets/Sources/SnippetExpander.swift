import Foundation

/// 組み込みプレースホルダを、プロセスを起動せずに展開する。
public enum SnippetExpander {

    /// 書けるプレースホルダ。コマンドラインのヘルプとドキュメントで使う。
    public static let placeholders: [(syntax: String, meaning: String)] = [
        ("{date}", "yyyy-MM-dd"),
        ("{date:<書式>}", "指定した書式（例 {date:yyyy年M月d日}）"),
        ("{time}", "HH:mm"),
        ("{time:<書式>}", "指定した書式（例 {time:HH時mm分}）"),
        ("{datetime}", "yyyy-MM-dd HH:mm:ss"),
        ("{uuid}", "小文字の UUID"),
    ]

    /// `Regex` は Sendable ではないが、リテラルから作った値は不変で読むだけなので
    /// 共有して安全。呼ばれるたびに組み立て直すのを避ける。
    private nonisolated(unsafe) static let pattern =
        /\{(?<name>[a-zA-Z]+)(?::(?<argument>[^}]*))?\}/

    /// - Parameter now: 展開に使う時刻。テストのために差し替えられる。
    public static func expand(_ text: String, now: Date = Date()) -> String {
        text.replacing(pattern) { match in
            // 空の引数は「無い」として扱う。空書式で内容が消えるのを防ぐ。
            let argument = match.argument.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
            return substitute(String(match.name), argument: argument, now: now)
                // 未知のものはリテラルとして残す。
                ?? String(match.0)
        }
    }

    private static func substitute(_ name: String, argument: String?, now: Date) -> String? {
        switch name.lowercased() {
        case "date":
            format(now, argument ?? "yyyy-MM-dd")
        case "time":
            format(now, argument ?? "HH:mm")
        case "datetime":
            format(now, argument ?? "yyyy-MM-dd HH:mm:ss")
        case "uuid":
            UUID().uuidString.lowercased()
        default:
            nil
        }
    }

    /// 暦とロケールを固定し、端末ごとに同じ書式を返す。
    private static func format(_ date: Date, _ template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = template
        return formatter.string(from: date)
    }
}
