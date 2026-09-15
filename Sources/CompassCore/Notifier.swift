import Foundation
import UserNotifications

/// 不備の伝え先。差し替えられるようにしておき、テストでは通知を出さずに記録する。
@MainActor
public protocol IssueReporting: AnyObject {
    func report(_ issues: [ConfigIssue])
    func report(title: String, body: String)
}

/// エラーだけを通知センターに出す。
///
/// 不可視の常駐プロセスなので設定の不備に気づく手段が通知しかない。一方で
/// **正常時は完全に黙る**。起動やリロード成功の通知は出さない（requirements.md 5.3）。
///
/// 通知の許可は**最初にエラーを出すときに初めて要求する。** エラーが起きなければ
/// 許可ダイアログも出ない。
@MainActor
public final class Notifier: IssueReporting {

    public static let shared = Notifier()

    private let log: Log
    /// 許可要求は 1 回だけ走らせる。Task を保持して結果を共有する。
    private var authorizationTask: Task<Bool, Never>?

    public init(log: Log = .shared) {
        self.log = log
    }

    /// 設定の不備を伝える。ファイルごとに 1 通にまとめる。
    public func report(_ issues: [ConfigIssue]) {
        guard !issues.isEmpty else { return }
        let byFile = Dictionary(grouping: issues, by: \.file)
        // 並びを固定して、同じ不備なら同じ順で通知が出るようにする。
        let messages = byFile.keys.sorted { $0.fileName < $1.fileName }.compactMap {
            file -> Message? in
            guard let items = byFile[file], !items.isEmpty else { return nil }
            return Message(
                title: "\(file.fileName) を読み込めなかった",
                body: items.map(\.detail).joined(separator: "\n")
            )
        }
        deliver(messages)
    }

    /// 任意のエラーを伝える。ホットキーの登録失敗などに使う。
    public func report(title: String, body: String) {
        deliver([Message(title: title, body: body)])
    }

    private struct Message: Sendable {
        var title: String
        var body: String
    }

    private func deliver(_ messages: [Message]) {
        // 通知が出せない環境でも**ログには必ず残す**。
        for message in messages {
            log.error("\(message.title): \(message.body)")
        }
        guard let center else { return }
        // **1 つの Task で順に送る。** 通知ごとに Task を起こすと、再開順が不定で
        // 並びが崩れ、許可要求も同時に複数走って確認ダイアログが二重に出る。
        Task { [messages, log] in
            guard await authorized(on: center) else { return }
            for message in messages {
                Self.send(message, on: center, log: log)
            }
        }
    }

    /// `UNUserNotificationCenter.current()` は bundle identifier が無いと落ちる。
    /// テストや `swift run` で動かす場合に備えて、使えるかを先に判定する。
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// 許可を得る。同時に呼ばれても要求は 1 回だけ。
    private func authorized(on center: UNUserNotificationCenter) async -> Bool {
        if let task = authorizationTask { return await task.value }

        let log = self.log
        let task = Task { () -> Bool in
            do {
                let granted = try await center.requestAuthorization(options: [.alert])
                if !granted {
                    log.warn("通知が許可されなかった。以後はログにのみ残す")
                }
                return granted
            } catch {
                log.warn("通知の許可を要求できなかった: \(error.localizedDescription)")
                return false
            }
        }
        authorizationTask = task
        return await task.value
    }

    /// **`async` 版の `add` は使わない。** `UNUserNotificationCenter` は Sendable では
    /// ないため、MainActor から nonisolated な `add` へ渡すと Swift 6 の並行性検査に
    /// 弾かれる。completion handler 版なら受け渡しが起きない。
    ///
    /// 投入は同期に済み、順序もそのまま保たれる。
    @MainActor
    private static func send(
        _ message: Message, on center: UNUserNotificationCenter, log: Log
    ) {
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            guard let error else { return }
            log.warn("通知を出せなかった: \(error.localizedDescription)")
        }
    }
}
