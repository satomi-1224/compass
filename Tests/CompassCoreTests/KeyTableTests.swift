import Testing

@testable import CompassCore

@Suite("KeyTable")
struct KeyTableTests {

    /// 現行 Hammerspoon から移植するキー。値を取り違えると別のキーに登録される。
    @Test("移植対象のキーが正しいコードを返す")
    func resolvesMigratedKeys() {
        #expect(KeyTable.keyCode(for: "t") == 17)
        #expect(KeyTable.keyCode(for: "f") == 3)
        #expect(KeyTable.keyCode(for: "b") == 11)
        #expect(KeyTable.keyCode(for: "k") == 40)
        #expect(KeyTable.keyCode(for: "v") == 9)
        #expect(KeyTable.keyCode(for: "w") == 13)
        #expect(KeyTable.keyCode(for: "space") == 49)
        #expect(KeyTable.keyCode(for: "return") == 36)
    }

    @Test("名前付きキーの別名は同じコードを指す")
    func aliasesMatch() {
        #expect(KeyTable.keyCode(for: "enter") == KeyTable.keyCode(for: "return"))
        #expect(KeyTable.keyCode(for: "esc") == KeyTable.keyCode(for: "escape"))
        #expect(KeyTable.keyCode(for: "backspace") == KeyTable.keyCode(for: "delete"))
    }

    /// `delete` は Backspace（左向き）を指す。Forward Delete と混ざると
    /// 「ウィンドウを閉じる」相当のキーで別の動作が起きる。
    @Test("delete と forwarddelete は別のキー")
    func deleteIsNotForwardDelete() {
        #expect(KeyTable.keyCode(for: "delete") == 51)
        #expect(KeyTable.keyCode(for: "forwarddelete") == 117)
    }

    @Test("大文字と余分な空白を許す")
    func ignoresCaseAndWhitespace() {
        #expect(KeyTable.keyCode(for: "T") == KeyTable.keyCode(for: "t"))
        #expect(KeyTable.keyCode(for: " Space ") == KeyTable.keyCode(for: "space"))
    }

    @Test("不明なキー名は nil")
    func rejectsUnknownName() {
        #expect(KeyTable.keyCode(for: "foo") == nil)
        #expect(KeyTable.keyCode(for: "") == nil)
        // 修飾キー自体は単キーとして書けない（トリガーに書く）。
        #expect(KeyTable.keyCode(for: "cmd") == nil)
    }

    @Test("一覧は名前順で重複がない")
    func allNamesAreSortedAndUnique() {
        let names = KeyTable.allNames
        #expect(names == names.sorted())
        #expect(Set(names).count == names.count)
        #expect(names.contains("space"))
    }

    @Test("一覧のすべての名前が解決できる")
    func everyNameResolves() {
        for name in KeyTable.allNames {
            #expect(KeyTable.keyCode(for: name) != nil, "\(name) が解決できない")
        }
    }
}
