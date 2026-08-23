import Foundation

/// `DispatchSource` を持ち、**参照が切れたら必ず cancel する。**
///
/// cancel しないまま解放された DispatchSource は libdispatch がプロセスごと落とす
/// （`BUG IN CLIENT OF LIBDISPATCH: Release of a source that has not been cancelled`）。
/// 片付けの呼び忘れが即クラッシュになるので、忘れようのない形にしておく。
///
/// **片付け役をこの型が引き受ける理由。** 持ち主はどれも `@MainActor` のクラスで、
/// その `deinit` は nonisolated なので自分のプロパティに触れない。`isolated deinit`
/// なら書けるが**実行時に macOS 15.4 以降を要求する**ため、macOS 14 を最低要件に
/// している compass では使えない（README「動作要件」）。片付けだけを
/// actor に属さないこの型へ逃がせば、素の `deinit` で確実に走る。
///
/// 片付けは**参照を捨てることだけで表す。** 明示的な `cancel()` は生やさない。
/// 二重解放や「もう cancel したか」を持ち主が気にせずに済む。
public final class ManagedSource {

    private let source: any DispatchSourceProtocol

    /// - Parameter source: `resume()` 済みの source を渡す。
    public init(_ source: any DispatchSourceProtocol) {
        self.source = source
    }

    deinit {
        source.cancel()
    }
}
