import Testing

@testable import CompassCore

/// 投げられた `ConfigIssues` を取り出す。投げられなければ nil。
///
/// **`#require(throws:) { }` の戻り値は使わない。** 投げられた値を返す形は
/// swift-testing の新しい版だけのもので、Command Line Tools が入れる Swift 6.0 では
/// `Void` を返す。README が「Command Line Tools だけで組める」と書いている以上、
/// テストもそこで動かせるようにしておく。
///
/// 呼び出し側は `try #require(thrownIssues { ... })` で受ける。投げられなかった場合も
/// 型違いの例外だった場合も nil になり、`#require` が呼び出し位置で落ちる。
func thrownIssues(_ body: () throws -> Any) -> ConfigIssues? {
    do {
        _ = try body()
        return nil
    } catch let issues as ConfigIssues {
        return issues
    } catch {
        return nil
    }
}
