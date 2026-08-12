import Carbon.HIToolbox
import CompassCore
import Testing

@testable import HotkeyEngine

@Suite("Carbon の修飾キー変換")
struct CarbonModifiersTests {

    @Test("既定のトリガーを変換する")
    func convertsDefaultTrigger() {
        #expect(
            Hotkeys.defaultTrigger.carbonFlags
                == UInt32(cmdKey) | UInt32(optionKey) | UInt32(shiftKey))
    }

    @Test("修飾キーごとに対応するビットが立つ")
    func mapsEachModifier() {
        #expect(Modifiers([.command]).carbonFlags == UInt32(cmdKey))
        #expect(Modifiers([.option]).carbonFlags == UInt32(optionKey))
        #expect(Modifiers([.shift]).carbonFlags == UInt32(shiftKey))
        #expect(Modifiers([.control]).carbonFlags == UInt32(controlKey))
    }

    /// Carbon のマスクは `NSEvent.ModifierFlags` とは別の値。取り違えると
    /// 意図と違う組み合わせで登録される。
    @Test("Carbon の値は NSEvent の値と一致しない")
    func carbonValuesAreDistinct() {
        // cmdKey = 1 << 8, shiftKey = 1 << 9, optionKey = 1 << 11, controlKey = 1 << 12
        #expect(Modifiers([.command]).carbonFlags == 256)
        #expect(Modifiers([.shift]).carbonFlags == 512)
        #expect(Modifiers([.option]).carbonFlags == 2048)
        #expect(Modifiers([.control]).carbonFlags == 4096)
    }

    @Test("空なら 0")
    func emptyIsZero() {
        #expect(Modifiers().carbonFlags == 0)
    }
}

@MainActor
@Suite("HotkeyEngine")
struct HotkeyEngineTests {

    private func binding(_ key: String, _ action: Action) throws -> HotkeyBinding {
        let code = try #require(KeyTable.keyCode(for: key))
        return HotkeyBinding(key: key, keyCode: code, action: action)
    }

    /// 他アプリと衝突しにくい組み合わせを使う。登録の成否は環境に依存するため、
    /// テストでは「登録数 + 失敗数 = 要求数」という不変条件を見る。
    private let trigger = Modifiers([.command, .option, .shift, .control])

    @Test("すべての binding が登録か失敗のどちらかになる")
    func everyBindingIsAccountedFor() throws {
        let engine = HotkeyEngine()
        let bindings = [
            try binding("f9", .command("true")),
            try binding("f10", .builtin(.search)),
            try binding("f11", .builtin(.clipboard)),
        ]

        let failures = engine.apply(Hotkeys(trigger: trigger, bindings: bindings))

        #expect(engine.registeredCount + failures.count == bindings.count)
        // 失敗したなら理由が hotkeys.toml の不備として届く。
        #expect(failures.allSatisfy { $0.file == .hotkeys })
        engine.unregisterAll()
        #expect(engine.registeredCount == 0)
    }

    /// **差分を取らず毎回すべて登録し直す。** 解除できていなければ 2 回目が
    /// `eventHotKeyExistsErr` で失敗して登録数が落ちる。
    @Test("apply を繰り返しても登録が積み上がらない")
    func applyIsIdempotent() throws {
        let engine = HotkeyEngine()
        let hotkeys = Hotkeys(trigger: trigger, bindings: [try binding("f9", .command("true"))])

        engine.apply(hotkeys)
        let first = engine.registeredCount

        engine.apply(hotkeys)
        #expect(engine.registeredCount == first)

        engine.unregisterAll()
    }

    @Test("空の設定を適用すると何も登録されない")
    func emptyBindingsRegisterNothing() {
        let engine = HotkeyEngine()
        let failures = engine.apply(Hotkeys(trigger: trigger, bindings: []))
        #expect(failures.isEmpty)
        #expect(engine.registeredCount == 0)
    }

    /// トリガーを変えたときに古い登録が残っていると、前のキーが効き続ける。
    @Test("トリガーを変えても登録数は変わらない")
    func changingTriggerReplacesRegistrations() throws {
        let engine = HotkeyEngine()
        let bindings = [try binding("f9", .command("true"))]

        engine.apply(Hotkeys(trigger: trigger, bindings: bindings))
        let first = engine.registeredCount

        engine.apply(Hotkeys(trigger: [.control, .option], bindings: bindings))
        #expect(engine.registeredCount == first)

        engine.unregisterAll()
    }
}
