import Testing

@testable import CompassCore

@Suite("Modifiers")
struct ModifiersTests {

    @Test("既定のトリガーを解釈する")
    func parsesDefaultTrigger() {
        #expect(Modifiers.parse("cmd+alt+shift") == [.command, .option, .shift])
    }

    @Test("別名を受け付ける")
    func acceptsAliases() {
        #expect(Modifiers.parse("command+option") == Modifiers.parse("cmd+alt"))
        #expect(Modifiers.parse("ctrl") == Modifiers.parse("control"))
        #expect(Modifiers.parse("opt") == Modifiers.parse("option"))
    }

    @Test("大文字と余分な空白を許す")
    func ignoresCaseAndWhitespace() {
        #expect(Modifiers.parse(" CMD + Shift ") == [.command, .shift])
    }

    /// 部分的に解釈して動かすと、意図と違う組み合わせで登録されて原因が分からなくなる。
    @Test("綴りが1つでも不明なら nil")
    func rejectsUnknownSpelling() {
        #expect(Modifiers.parse("cmd+foo") == nil)
        #expect(Modifiers.parse("hyper") == nil)
    }

    @Test("空のトリガーは受け付けない")
    func rejectsEmpty() {
        #expect(Modifiers.parse("") == nil)
        #expect(Modifiers.parse("+") == nil)
        #expect(Modifiers.parse("   ") == nil)
    }

    @Test("表示は macOS の慣例順に並べる")
    func symbolsFollowConvention() {
        #expect(Modifiers([.command, .option, .shift]).symbols == "⌥⇧⌘")
        #expect(Modifiers([.control, .command]).symbols == "⌃⌘")
    }
}
