import Foundation

/// 標準エラーに書くだけのログ。
///
/// **標準出力は空けておく。** `--print-candidates` のように結果を出す入口があり、
/// ログが混ざると機械的に読めなくなる。
///
/// launchd から起動したときは home-manager モジュールが指定したファイルへ
/// リダイレクトされる。前景で動かしたときは端末に出る。
public struct Log: Sendable {

    public enum Level: Int, Sendable, Comparable, CaseIterable {
        case debug, info, warn, error, off

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        public var name: String {
            switch self {
            case .debug: "debug"
            case .info: "info"
            case .warn: "warn"
            case .error: "error"
            case .off: "off"
            }
        }

        public init?(name: String) {
            guard let match = Self.allCases.first(where: { $0.name == name.lowercased() } ) else {
                return nil
            }
            self = match
        }
    }

    /// 既定のログ。`COMPASS_LOG_LEVEL` で粒度を変えられる。
    public static let shared = Log(
        minimum: ProcessInfo.processInfo.environment["COMPASS_LOG_LEVEL"]
            .flatMap(Level.init(name:)) ?? .info
    )

    public let minimum: Level

    public init(minimum: Level = .info) {
        self.minimum = minimum
    }

    public func debug(_ message: String) { write(.debug, message) }
    public func info(_ message: String) { write(.info, message) }
    public func warn(_ message: String) { write(.warn, message) }
    public func error(_ message: String) { write(.error, message) }

    private func write(_ level: Level, _ message: String) {
        guard level != .off, level >= minimum else { return }
        // **標準エラーへ出す。** `--print-candidates` の結果（標準出力）に混ざると
        // 機械的に読めなくなる。実際、ファイル検索が 0 件のときの警告が候補一覧の
        // 中に紛れていた。launchd から起動したときは home-manager モジュールが
        // 標準出力と標準エラーの両方を同じログファイルへ向けるので、見え方は変わらない。
        //
        // **毎回流す。** 端末以外へ繋がるとフルバッファになり、数 KB 溜まるまで
        // 1 行も見えない（launchd 経由のログファイルがこれに当たる。実際に空の
        // ログを見て気づいた）。ログの頻度は低いのでコストは問題にならない。
        fputs("\(Self.timestamp()) [\(level.name)] \(message)\n", stderr)
        fflush(stderr)
    }

    /// `DateFormatter` は Sendable でないため共有せず、その場で作る。
    /// ログの頻度は低いので割に合う。
    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
