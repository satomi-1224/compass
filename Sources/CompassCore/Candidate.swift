import Foundation

/// 検索窓に並ぶ候補 1 件。
///
/// アプリ・ファイル・Web・クリップボード履歴・スニペットを同じ形で扱い、
/// SearchUI がどれも同じ見た目で並べられるようにする（requirements.md 6章）。
public struct Candidate: Equatable, Sendable, Identifiable {
    /// 一覧を作り直しても選択位置を保てるようにするための識別子。
    public var id: String
    public var title: String
    public var subtitle: String?
    /// アイコンを取りに行くパス。アプリとファイルのときだけ入る。
    public var iconPath: String?
    public var action: CandidateAction

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        iconPath: String? = nil,
        action: CandidateAction
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.iconPath = iconPath
        self.action = action
    }
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
}

/// 一覧に 1 行で出すための整形。
///
/// クリップボード履歴もスニペットも複数行のテキストを持ちうる。そのまま出すと
/// 行が崩れるので、畳んで切る。
public enum TextSummary {

    public static func line(of text: String, limit: Int = 120) -> String {
        let folded = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard folded.count > limit else { return folded }
        return String(folded.prefix(limit)) + "…"
    }
}
