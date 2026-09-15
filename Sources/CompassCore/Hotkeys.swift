import Foundation

/// ホットキーが起こすこと。
///
/// 本体アクション、登録済みプラグイン、外部コマンドのどれを呼ぶかだけを持つ。
/// プラグイン固有の型をここへ持ち込まないため、新しいプラグインを足しても
/// CompassCore の列挙を増やす必要はない。
public enum Action: Equatable, Sendable {
    case builtin(BuiltinAction)
    case plugin(String)
    case command(String)
}

public enum BuiltinAction: String, Equatable, Sendable, CaseIterable {
    case search
    case clipboard
}

/// 登録するキー 1 つ。
public struct HotkeyBinding: Equatable, Sendable {
    /// 設定に書かれていた綴り。通知やログに出すために持つ。
    public var key: String
    public var keyCode: UInt16
    public var action: Action

    public init(key: String, keyCode: UInt16, action: Action) {
        self.key = key
        self.keyCode = keyCode
        self.action = action
    }
}

/// `hotkeys.toml` の内容。
///
/// トリガーを 1 箇所だけ定義し、各アクションは単キーのみを指定する
/// （requirements.md 3.1）。トリガーを無視した個別指定や複数トリガーは受け付けない。
public struct Hotkeys: Equatable, Sendable {
    public var trigger: Modifiers
    public var bindings: [HotkeyBinding]

    public init(trigger: Modifiers = Hotkeys.defaultTrigger, bindings: [HotkeyBinding] = []) {
        self.trigger = trigger
        self.bindings = bindings
    }

    /// 既定のトリガー。現行 `command_launcher.mods` と同じ組み合わせで、
    /// 指の記憶を引き継げる（requirements.md 3.1）。
    public static let defaultTrigger = Modifiers([.command, .option, .shift])

    /// ファイルが無い・空のときの既定。`+Space` の検索窓だけは既定で入る。
    public static var fallback: Hotkeys {
        Hotkeys(trigger: defaultTrigger, bindings: defaultBindings)
    }

    /// `+Space` → 検索窓。requirements.md 3.1 の「デフォルト固定」を、
    /// **明示的な設定があればそちらを優先する既定値**として実装している。
    static var defaultBindings: [HotkeyBinding] {
        guard let code = KeyTable.keyCode(for: "space") else { return [] }
        return [HotkeyBinding(key: "space", keyCode: code, action: .builtin(.search))]
    }
}

// MARK: - パース

extension Hotkeys {

    public static func parse(
        _ toml: String, pluginActions: Set<String> = []
    ) throws -> Hotkeys {
        let raw: Raw
        do {
            raw = try tomlDecoder.decode(Raw.self, from: toml)
        } catch {
            throw ConfigIssues([ConfigIssue(file: .hotkeys, detail: "解釈できない: \(error)")])
        }

        var issues = IssueCollector(file: .hotkeys)

        var trigger = defaultTrigger
        if let text = raw.trigger {
            if let parsed = Modifiers.parse(text) {
                // **shift だけのトリガーは受け付けない。** 通常のタイピングまで
                // ホットキー候補になり、大文字入力が丸ごと奪われる。
                if parsed.isDisjoint(with: [.command, .option, .control]) {
                    issues.add("trigger には cmd / alt / ctrl のいずれかが必要: \(text)")
                } else {
                    trigger = parsed
                }
            } else {
                issues.add(
                    "trigger を解釈できない: \(text)"
                        + "（書ける綴り: \(Modifiers.allSpellings.joined(separator: " / "))）")
            }
        }

        // **キーコードで衝突を見る。** `return` と `enter` は同じ物理キーなので、
        // 綴りが違っても衝突として検出しなければ片方が黙って無効になる。
        var claimed: [UInt16: (key: String, section: String)] = [:]
        var bindings: [HotkeyBinding] = []

        func resolve(_ name: String, section: String) -> UInt16? {
            guard let code = KeyTable.keyCode(for: name) else {
                issues.add("[\(section)] のキー名が不明: \(name)")
                return nil
            }
            if let existing = claimed[code] {
                issues.add(
                    "同じキーが 2 箇所にある: [\(existing.section)] \(existing.key)"
                        + " と [\(section)] \(name)")
                return nil
            }
            claimed[code] = (name, section)
            return code
        }

        // **並びを固定する。** 辞書の順序は不定なので、そのまま回すとエラーの出方が
        // 実行ごとに変わって原因を追いにくい。
        let actions = raw.actions ?? [:]
        for name in actions.keys.sorted() {
            guard let text = actions[name] else { continue }
            guard let code = resolve(name, section: "actions") else { continue }

            let action: Action
            if let builtin = BuiltinAction(rawValue: text) {
                action = .builtin(builtin)
            } else if pluginActions.contains(text) {
                action = .plugin(text)
            } else {
                let candidates = (BuiltinAction.allCases.map(\.rawValue) + Array(pluginActions))
                    .sorted()
                    .joined(separator: " / ")
                issues.add(
                    "[actions] \(name) の値が不明: \(text)（候補: \(candidates)）")
                continue
            }
            bindings.append(HotkeyBinding(key: name, keyCode: code, action: action))
        }

        let commands = raw.commands ?? [:]
        for name in commands.keys.sorted() {
            guard let command = commands[name] else { continue }
            guard !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                issues.add("[commands] \(name) のコマンドが空")
                continue
            }
            guard let code = resolve(name, section: "commands") else { continue }
            bindings.append(HotkeyBinding(key: name, keyCode: code, action: .command(command)))
        }

        try issues.throwIfNeeded()

        // 検索窓は既定で入る。明示的に space が割り当てられていればそちらが勝つ。
        if let spaceCode = KeyTable.keyCode(for: "space"),
            !bindings.contains(where: { $0.keyCode == spaceCode })
        {
            bindings.append(
                HotkeyBinding(key: "space", keyCode: spaceCode, action: .builtin(.search)))
        }

        return Hotkeys(trigger: trigger, bindings: bindings)
    }

    fileprivate struct Raw: Decodable {
        var trigger: String?
        var actions: [String: String]?
        var commands: [String: String]?
    }
}
