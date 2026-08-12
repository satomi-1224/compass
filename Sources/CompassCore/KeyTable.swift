import Carbon.HIToolbox
import Foundation

/// 設定に書けるキー名と仮想キーコードの対応。
///
/// 設定の検証（不明なキー名の検出）に必要なため、ホットキー登録を受け持つ
/// HotkeyEngine ではなくここに置く。**値は Carbon の `kVK_*` から取る。**
/// 数字をハードコードすると取り違えても気づけない。
///
/// キーコードは物理キーの位置を指す。US ANSI 配列での刻印を名前にしている。
public enum KeyTable {

    private static let entries: [(name: String, code: UInt16)] = {
        var table: [(String, UInt16)] = [
            // 英字
            ("a", UInt16(kVK_ANSI_A)), ("b", UInt16(kVK_ANSI_B)), ("c", UInt16(kVK_ANSI_C)),
            ("d", UInt16(kVK_ANSI_D)), ("e", UInt16(kVK_ANSI_E)), ("f", UInt16(kVK_ANSI_F)),
            ("g", UInt16(kVK_ANSI_G)), ("h", UInt16(kVK_ANSI_H)), ("i", UInt16(kVK_ANSI_I)),
            ("j", UInt16(kVK_ANSI_J)), ("k", UInt16(kVK_ANSI_K)), ("l", UInt16(kVK_ANSI_L)),
            ("m", UInt16(kVK_ANSI_M)), ("n", UInt16(kVK_ANSI_N)), ("o", UInt16(kVK_ANSI_O)),
            ("p", UInt16(kVK_ANSI_P)), ("q", UInt16(kVK_ANSI_Q)), ("r", UInt16(kVK_ANSI_R)),
            ("s", UInt16(kVK_ANSI_S)), ("t", UInt16(kVK_ANSI_T)), ("u", UInt16(kVK_ANSI_U)),
            ("v", UInt16(kVK_ANSI_V)), ("w", UInt16(kVK_ANSI_W)), ("x", UInt16(kVK_ANSI_X)),
            ("y", UInt16(kVK_ANSI_Y)), ("z", UInt16(kVK_ANSI_Z)),

            // 数字
            ("0", UInt16(kVK_ANSI_0)), ("1", UInt16(kVK_ANSI_1)), ("2", UInt16(kVK_ANSI_2)),
            ("3", UInt16(kVK_ANSI_3)), ("4", UInt16(kVK_ANSI_4)), ("5", UInt16(kVK_ANSI_5)),
            ("6", UInt16(kVK_ANSI_6)), ("7", UInt16(kVK_ANSI_7)), ("8", UInt16(kVK_ANSI_8)),
            ("9", UInt16(kVK_ANSI_9)),

            // 記号
            ("minus", UInt16(kVK_ANSI_Minus)), ("equal", UInt16(kVK_ANSI_Equal)),
            ("leftbracket", UInt16(kVK_ANSI_LeftBracket)),
            ("rightbracket", UInt16(kVK_ANSI_RightBracket)),
            ("backslash", UInt16(kVK_ANSI_Backslash)),
            ("semicolon", UInt16(kVK_ANSI_Semicolon)), ("quote", UInt16(kVK_ANSI_Quote)),
            ("comma", UInt16(kVK_ANSI_Comma)), ("period", UInt16(kVK_ANSI_Period)),
            ("slash", UInt16(kVK_ANSI_Slash)), ("grave", UInt16(kVK_ANSI_Grave)),

            // 編集・移動
            ("space", UInt16(kVK_Space)),
            ("return", UInt16(kVK_Return)), ("enter", UInt16(kVK_Return)),
            ("tab", UInt16(kVK_Tab)),
            ("delete", UInt16(kVK_Delete)), ("backspace", UInt16(kVK_Delete)),
            ("forwarddelete", UInt16(kVK_ForwardDelete)),
            ("escape", UInt16(kVK_Escape)), ("esc", UInt16(kVK_Escape)),
            ("home", UInt16(kVK_Home)), ("end", UInt16(kVK_End)),
            ("pageup", UInt16(kVK_PageUp)), ("pagedown", UInt16(kVK_PageDown)),
            ("left", UInt16(kVK_LeftArrow)), ("right", UInt16(kVK_RightArrow)),
            ("up", UInt16(kVK_UpArrow)), ("down", UInt16(kVK_DownArrow)),

            // ファンクション
            ("f1", UInt16(kVK_F1)), ("f2", UInt16(kVK_F2)), ("f3", UInt16(kVK_F3)),
            ("f4", UInt16(kVK_F4)), ("f5", UInt16(kVK_F5)), ("f6", UInt16(kVK_F6)),
            ("f7", UInt16(kVK_F7)), ("f8", UInt16(kVK_F8)), ("f9", UInt16(kVK_F9)),
            ("f10", UInt16(kVK_F10)), ("f11", UInt16(kVK_F11)), ("f12", UInt16(kVK_F12)),
        ]
        table.sort { $0.0 < $1.0 }
        return table
    }()

    private static let byName: [String: UInt16] = Dictionary(
        entries.map { ($0.name, $0.code) },
        uniquingKeysWith: { first, _ in first }
    )

    /// キー名から仮想キーコードを引く。大文字小文字は区別しない。
    public static func keyCode(for name: String) -> UInt16? {
        byName[name.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// 書けるキー名の一覧。エラーメッセージと `--print-keys` に使う。
    public static var allNames: [String] { entries.map(\.name) }
}
