import Testing

@testable import CompassCore

@Suite("Hotkeys のパース")
struct HotkeysTests {

    /// requirements.md 4章の設定例をそのまま読む。
    @Test("要件に載っている設定例を読める")
    func parsesDocumentedExample() throws {
        let toml = """
            trigger = "cmd+alt+shift"

            [actions]
            space = "search"
            v     = "clipboard"
            w     = "snippets"

            [commands]
            t      = "open -a WezTerm"
            f      = "open -a Finder"
            b      = "open -a 'Google Chrome'"
            k      = "open ~/Applications/Remap.app"
            return = "pgrep -f MagicBoard && pkill -f MagicBoard || ~/bin/MagicBoard &"
            """

        let hotkeys = try Hotkeys.parse(toml, pluginActions: ["snippets"])

        #expect(hotkeys.trigger == [.command, .option, .shift])
        #expect(hotkeys.bindings.count == 8)

        let space = hotkeys.bindings.first { $0.key == "space" }
        #expect(space?.action == .builtin(.search))

        let snippets = hotkeys.bindings.first { $0.key == "w" }
        #expect(snippets?.action == .plugin("snippets"))

        let terminal = hotkeys.bindings.first { $0.key == "t" }
        #expect(terminal?.action == .command("open -a WezTerm"))
        #expect(terminal?.keyCode == KeyTable.keyCode(for: "t"))
    }

    /// home-manager の `pkgs.formats.toml` が生成する形をそのまま読む。
    /// **キーはアルファベット順に並び替えられ、`$` を含む値はリテラル文字列になる。**
    /// モジュールとパーサが食い違ったらここで落ちる。
    @Test("home-manager が生成する TOML を読める")
    func parsesGeneratedTOML() throws {
        let toml = """
            trigger = "cmd+alt+shift"

            [actions]
            space = "search"
            v = "clipboard"
            w = "snippets"

            [commands]
            k = 'open "$HOME/Applications/Chrome Apps.localized/Remap.app"'
            t = "open -a WezTerm"
            """

        let hotkeys = try Hotkeys.parse(toml, pluginActions: ["snippets"])

        #expect(hotkeys.trigger == [.command, .option, .shift])
        #expect(hotkeys.bindings.count == 5)
        // リテラル文字列なので `$HOME` はそのまま入る。展開は `sh` に任せる。
        let remap = hotkeys.bindings.first { $0.key == "k" }
        #expect(
            remap?.action
                == .command(#"open "$HOME/Applications/Chrome Apps.localized/Remap.app""#))
    }

    @Test("trigger を省略すると既定になる")
    func triggerDefaults() throws {
        let hotkeys = try Hotkeys.parse(#"[commands]\#nt = "open -a WezTerm""#)
        #expect(hotkeys.trigger == Hotkeys.defaultTrigger)
        #expect(Hotkeys.defaultTrigger == [.command, .option, .shift])
    }

    @Test("trigger を解釈できなければエラー")
    func rejectsUnknownTrigger() throws {
        let issues = try #require(thrownIssues {
            try Hotkeys.parse(#"trigger = "hyper""#)
        })
        #expect(issues.items[0].file == .hotkeys)
        #expect(issues.items[0].detail.contains("trigger"))
    }

    /// shift だけだと通常のタイピングまでホットキー候補になり、大文字入力が奪われる。
    @Test("shift だけの trigger は受け付けない")
    func rejectsShiftOnlyTrigger() throws {
        let issues = try #require(thrownIssues {
            try Hotkeys.parse(#"trigger = "shift""#)
        })
        #expect(issues.items[0].detail.contains("cmd"))
    }

    @Test("cmd / alt / ctrl のいずれかがあれば単独でも通す")
    func acceptsSingleStrongModifier() throws {
        #expect(try Hotkeys.parse(#"trigger = "ctrl""#).trigger == [.control])
        #expect(try Hotkeys.parse(#"trigger = "cmd+shift""#).trigger == [.command, .shift])
    }

    // MARK: - 衝突

    @Test("同じキーが actions と commands の両方にあればエラー")
    func rejectsCollisionAcrossSections() throws {
        let toml = """
            [actions]
            v = "clipboard"

            [commands]
            v = "open -a Finder"
            """
        let issues = try #require(thrownIssues { try Hotkeys.parse(toml) })
        #expect(issues.items.contains { $0.detail.contains("同じキー") })
    }

    /// `return` と `enter` は同じ物理キー。綴りが違っても衝突として検出しなければ
    /// 片方が黙って無効になる。
    @Test("別名で書かれた同じ物理キーも衝突として検出する")
    func detectsCollisionThroughAliases() {
        let toml = """
            [actions]
            return = "search"

            [commands]
            enter = "open -a Finder"
            """
        #expect(throws: ConfigIssues.self) { try Hotkeys.parse(toml) }
    }

    // MARK: - 値の検証

    @Test("不明なキー名はエラー")
    func rejectsUnknownKeyName() throws {
        let issues = try #require(thrownIssues {
            try Hotkeys.parse(#"[commands]\#nfoo = "open -a Finder""#)
        })
        #expect(issues.items[0].detail.contains("foo"))
    }

    @Test("actions の値は本体または登録済みプラグインのみ")
    func rejectsUnknownAction() throws {
        let issues = try #require(thrownIssues {
            try Hotkeys.parse(#"[actions]\#nv = "paste""#)
        })
        #expect(issues.items[0].detail.contains("search"))
        #expect(issues.items[0].detail.contains("clipboard"))
    }

    @Test("未登録のプラグイン名は拒否する")
    func rejectsUnregisteredPluginAction() {
        #expect(throws: ConfigIssues.self) {
            try Hotkeys.parse(#"[actions]\#nw = "snippets""#)
        }
    }

    @Test("空のコマンドはエラー")
    func rejectsEmptyCommand() {
        #expect(throws: ConfigIssues.self) {
            try Hotkeys.parse(#"[commands]\#nt = "   ""#)
        }
    }

    /// 辞書の順序は不定。そのまま回すとエラーの出方が実行ごとに変わって原因を追いにくい。
    @Test("複数のエラーは毎回同じ順で出る")
    func issueOrderIsStable() throws {
        let toml = """
            [commands]
            zzz = "x"
            aaa = "y"
            mmm = "z"
            """
        var expected: [String] = []
        for _ in 0..<5 {
            let issues = try #require(thrownIssues { try Hotkeys.parse(toml) })
            let details = issues.items.map(\.detail)
            if expected.isEmpty {
                expected = details
                #expect(details.count == 3)
            } else {
                #expect(details == expected)
            }
        }
    }

    // MARK: - 検索窓の既定

    @Test("空でも検索窓は既定で入る")
    func searchIsAlwaysBound() throws {
        let hotkeys = try Hotkeys.parse("")
        #expect(hotkeys.trigger == Hotkeys.defaultTrigger)
        #expect(hotkeys.bindings.count == 1)
        #expect(hotkeys.bindings[0].key == "space")
        #expect(hotkeys.bindings[0].action == .builtin(.search))
    }

    @Test("space を明示的に割り当てたらそちらが勝つ")
    func explicitSpaceWins() throws {
        let hotkeys = try Hotkeys.parse(#"[commands]\#nspace = "open -a Finder""#)
        let bound = hotkeys.bindings.filter { $0.keyCode == KeyTable.keyCode(for: "space") }
        #expect(bound.count == 1)
        #expect(bound[0].action == .command("open -a Finder"))
    }

    @Test("fallback は検索窓を含む")
    func fallbackBindsSearch() {
        let fallback = Hotkeys.fallback
        #expect(fallback.trigger == Hotkeys.defaultTrigger)
        #expect(fallback.bindings.contains { $0.action == .builtin(.search) })
    }
}
