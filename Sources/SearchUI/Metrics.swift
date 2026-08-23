import AppKit

/// 検索窓の寸法とフォント。
///
/// **入力欄と候補行が同じ値を使う。** 別々に持つと、入力した文字と候補のタイトルで
/// 左端が揃わない（実際にそうなっていた）。目が最初に追うのは文字の始まりなので、
/// ここがずれると全体が雑に見える。
///
/// 余白は 4pt を単位に取り、要素の高さはフォントサイズの 2.2〜2.5 倍に置いている。
enum Metrics {

    // MARK: 横方向

    /// 窓の縁からアイコンまで。
    static let horizontalPadding: CGFloat = 20
    /// アイコンに割り当てる幅。**入力欄のシンボルと候補のアイコンで共通。**
    static let iconWidth: CGFloat = 24
    /// アイコンとテキストの間隔。
    static let iconGap: CGFloat = 12

    /// テキストが始まる位置。入力欄と候補行はこれを揃える。
    static var textInset: CGFloat { horizontalPadding + iconWidth + iconGap }

    // MARK: 縦方向

    /// 入力欄の高さ。22pt の文字に対して上下に 17pt ずつ空く。
    static let inputHeight: CGFloat = 56
    /// 候補 1 行の高さ。タイトル + サブタイトルで 27pt、上下に 10pt ずつ。
    static let rowHeight: CGFloat = 48
    static let separatorThickness: CGFloat = 1

    // MARK: 角丸と選択

    static let cornerRadius: CGFloat = 14
    /// 選択ハイライトを窓の縁から離す量。アイコンの左に 8pt の余白が残る。
    static let selectionInset: CGFloat = 12
    static let selectionVerticalInset: CGFloat = 3
    static let selectionRadius: CGFloat = 8

    // MARK: フォント

    // `NSFont` は Sendable でないため `static let` に置けない。値を持たない
    // computed property にして、呼ばれるたびに作る（キャッシュは AppKit が持つ）。

    /// 入力欄。**light は使わない。** この大きさでは細すぎて輪郭がぼやける。
    static var inputFont: NSFont { .systemFont(ofSize: 22, weight: .regular) }
    /// 候補のタイトル。
    static var titleFont: NSFont { .systemFont(ofSize: 14, weight: .regular) }
    /// 候補のタイトルのうち、入力に当たった文字。
    ///
    /// **同じサイズのまま太さだけ変える。** サイズを変えると 1 行の中で文字の
    /// 高さが揃わず、字が踊って見える。
    static var titleMatchFont: NSFont { .systemFont(ofSize: 14, weight: .bold) }
    /// 候補のサブタイトル。サイズ差と色差の両方で階層を作る。
    static var subtitleFont: NSFont { .systemFont(ofSize: 11, weight: .regular) }
    /// タイトルとサブタイトルの行間。
    static let titleSpacing: CGFloat = 2

    /// シンボルの大きさ。`iconWidth` の枠内に収める。
    static let symbolPointSize: CGFloat = 17

    /// SF Symbol を `iconWidth` の枠に収まる大きさで作る。
    static func symbol(named name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: symbolPointSize, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }
}
