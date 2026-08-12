import Foundation

/// 外部コマンドを実行する。
///
/// ホットキーの実行モデルは**外部コマンド実行のみ**（requirements.md 3.3）。
/// 組み込みアクションは UI を伴うため、ここでは扱わず呼び出し側が振り分ける。
///
/// `/bin/sh -c` を通すため、`~` や `$HOME` の展開、`&&` や末尾の `&` が
/// そのまま使える（requirements.md 7.3 の MagicBoard トグルがこれに依存する）。
public enum ActionRunner {

    /// コマンドを起動して**終了を待たない。**
    ///
    /// ランチャーは押した瞬間に返る必要がある。終了を待つと、起動の遅いアプリで
    /// 次のキー入力が詰まる。
    ///
    /// - Returns: 起動できたか。コマンド自体の成否ではない。
    @discardableResult
    public static func run(_ command: String, log: Log = .shared) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        // 出力を読む相手がいない。パイプを繋いだままにすると、書き込み側が
        // バッファを埋めた時点で止まる。
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            log.debug("実行: \(command)")
            return true
        } catch {
            log.error("実行できなかった: \(command) — \(error.localizedDescription)")
            return false
        }
    }
}
