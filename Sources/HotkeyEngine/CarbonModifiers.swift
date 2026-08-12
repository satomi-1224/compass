import Carbon.HIToolbox
import CompassCore

extension Modifiers {
    /// Carbon のホットキー API が使う修飾キーマスクへ変換する。
    ///
    /// `cmdKey` などは Carbon 固有の値で、`NSEvent.ModifierFlags` とは別物。
    /// この変換を CompassCore に置かないのは、設定の語彙と登録の実装を混ぜないため。
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        return flags
    }
}
