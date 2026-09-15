import Foundation

/// 検索窓に並ぶ候補 1 件。
///
/// アプリ・ファイル・Web・クリップボード履歴・プラグインを同じ形で扱い、
/// SearchUI がどれも同じ見た目で並べられるようにする（requirements.md 6章）。
public struct Candidate: Equatable, Sendable, Identifiable {
    /// 一覧を作り直しても選択位置を保てるようにするための識別子。
    public var id: String
    public var title: String
    public var subtitle: String?
    /// 左に出す絵。**すべての候補が持つ。**
    ///
    /// 持たない候補があると、その行だけ文字の左に空白が空く。一覧の中で
    /// 揃っていない行が混ざると崩れて見える。
    public var icon: CandidateIcon
    public var action: CandidateAction
    /// title 以外にも照合する文字列。**画面には出さない。**
    ///
    /// アプリは Finder と同じ表示名（「システム設定」）を title にするので、英名
    /// （`System Settings`）をここへ入れて**どちらで打っても見つかる**ようにする。
    /// 逆向き（英名を title、日本語を別名）にしないのは、目に入る文字と打つ文字が
    /// 食い違うと「これで合っているのか」が分からなくなるため。
    public var aliases: [String]

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        icon: CandidateIcon,
        action: CandidateAction,
        aliases: [String] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.action = action
        self.aliases = aliases
    }
}

/// 候補の左に出す絵。
public enum CandidateIcon: Equatable, Sendable {
    /// アプリやファイルのアイコンをパスから取る。
    case file(path: String)
    /// SF Symbol。パスを持たない候補（Web 検索・履歴・プラグイン）に使う。
    case symbol(String)
}

/// 候補を選んだときに起きること。
///
/// `Enter` だけで実行し、修飾キーによる副アクションは持たない
/// （requirements.md 3.2）。
public enum CandidateAction: Equatable, Sendable {
    /// 既定のアプリで開く。アプリバンドルなら起動する。
    case open(path: String)
    /// ブラウザで開く。
    case openURL(URL)
    /// クリップボードへ載せて `Cmd+V` を送る。
    case paste(String)
    /// 外部コマンドの出力を貼る。
    ///
    /// **選ばれてから実行する。** 一覧を開くだけで走らせると、副作用のある
    /// コマンドを書いていた場合に選んでいないのに実行されてしまう。
    case pasteCommandOutput(String)
    /// 登録済みプラグインのコマンドを呼ぶ。
    ///
    /// UI 遷移を伴いうるため `ActionRunner` ではなく、プラグインレジストリを持つ
    /// `SearchController` が解決する。
    case invokePluginCommand(String)
}

/// 一覧に 1 行で出すための整形。
///
/// クリップボード履歴やプラグイン候補は複数行のテキストを持ちうる。そのまま出すと
/// 行が崩れるので、畳んで切る。
public enum TextSummary {

    /// 先に切り出す長さの、`limit` に対する倍率。
    ///
    /// 空白だけが続く入力でも `limit` 文字ぶんの中身が残るように、余裕を持たせる。
    private static let scanFactor = 8

    public static func line(of text: String, limit: Int = 120) -> String {
        // **全長を走査しない。** クリップボード履歴には数 MB のテキストが入りうる。
        // 畳んでから切るので、切る長さの数倍だけ見れば結果は変わらない。全長を
        // 畳もうとすると、履歴を開いた瞬間に窓が固まる（50 件ぶん走査される）。
        let scanned = text.prefix(limit * scanFactor)
        let clipped = scanned.endIndex != text.endIndex

        let folded = scanned
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")

        guard folded.count > limit else {
            // 切り出しの時点で落とした分があるなら、短く畳めても省略は示す。
            return clipped ? folded + "…" : folded
        }
        return String(folded.prefix(limit)) + "…"
    }
}
