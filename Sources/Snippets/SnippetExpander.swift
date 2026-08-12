import CompassCore
import Foundation

/// 組み込みプレースホルダを展開する。
///
/// **プロセスは起動しない**（requirements.md 3.5）。現行 Hammerspoon の `now`
/// （`os.date("%Y-%m-%d")`）はこれで表現できる。外部コマンドの出力が要るものは
/// `body_command` を使う。
public enum SnippetExpander {

    /// 書けるプレースホルダ。`--print-placeholders` とドキュメントで使う。
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
            substitute(
                String(match.name),
                argument: match.argument.map(String.init),
                now: now
            )
                // **知らないものはそのまま残す。** `{foo}` をリテラルとして
                // 書きたいことがある。
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

    /// **暦とロケールを固定する。** 端末の設定によって `yyyy` が和暦になったり、
    /// 月名が訳されたりすると、書式を指定した意味がなくなる。
    private static func format(_ date: Date, _ template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = template
        return formatter.string(from: date)
    }
}
