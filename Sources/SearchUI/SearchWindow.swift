import AppKit
import CompassCore

/// `.borderless` の NSPanel は既定でキーウィンドウになれない。
/// 入力を受けるためにオーバーライドする。
@MainActor
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 検索窓のウィンドウとビュー。
///
/// **`.nonactivatingPanel` を使う。** 通常のウィンドウだと compass がアクティブに
/// なってメニューバーを奪い、閉じたあとのフォーカス復帰も一手間増える。
/// nonactivating なら前面のアプリを保ったままキー入力を受けられるので、
/// クリップボード履歴やプラグイン候補のペースト先が変わらない。
///
/// 寸法は `Metrics` に集めてある。**入力欄の左にアイコンを置くのは装飾ではなく、
/// 入力した文字と候補のタイトルの左端を揃えるため。**
@MainActor
final class SearchWindow: NSObject, NSTextFieldDelegate, NSWindowDelegate {

    /// 入力が変わった。
    var onQueryChange: ((String) -> Void)?
    /// `Enter` が押された。
    var onSubmit: (() -> Void)?
    /// `Esc` が押された。**元のアプリへ戻すのはこの経路だけ。**
    var onCancel: (() -> Void)?
    /// 他のアプリへ移ったので閉じるべき。
    ///
    /// `onCancel` と分けているのは、**ここで元のアプリを呼び戻すとユーザーが
    /// 今クリックした相手を追い越してしまう**（Safari で開いて Terminal を
    /// クリックすると Safari が前に出る）。
    var onResignKey: (() -> Void)?

    /// 画面の上端からどれだけ下げるか。上寄り中央に出す（requirements.md 3.2）。
    private static let verticalInset: CGFloat = 0.18
    /// 画面の下端に残す余白。ぴったり接すると見づらい。
    private static let bottomMargin: CGFloat = 20

    private let panel: KeyablePanel
    private let input = NSTextField()
    private let symbolView = NSImageView()
    private let separator = NSBox()
    private let table = CandidateTable()
    private let container = NSVisualEffectView()
    private let maxVisibleRows: Int
    private let log: Log

    /// 高さは制約で決める。**隠すだけでは制約が残り、内容の高さと panel の高さが
    /// 食い違って入力欄の上端が切れる。**
    private var separatorHeight: NSLayoutConstraint?
    private var tableHeight: NSLayoutConstraint?

    init(width: CGFloat, maxVisibleRows: Int, log: Log = .shared) {
        self.maxVisibleRows = max(1, maxVisibleRows)
        self.log = log
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: Metrics.inputHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        build()
    }

    // MARK: - 状態

    var isVisible: Bool { panel.isVisible }
    var query: String { input.stringValue }
    var selected: Candidate? { table.selected }
    /// 今 1 件でも候補が出ているか。状態行だけの場合は false。
    var hasCandidates: Bool { table.selected != nil }
    /// 表に出ている行数。状態行を含む。テストから見るために持つ。
    var rowCount: Int { table.count }
    /// 入力欄の選択範囲。テストから見るために持つ。
    var selectedInputRange: NSRange? {
        (panel.fieldEditor(false, for: input) as? NSTextView)?.selectedRange()
    }

    /// 通知の宛先を切る。**入れ替えで捨てる窓に対して呼ぶ。**
    ///
    /// 捨てる窓が `onResignKey` を投げると、入れ替わったばかりの新しい窓が閉じる。
    func detach() {
        onQueryChange = nil
        onSubmit = nil
        onCancel = nil
        onResignKey = nil
        panel.delegate = nil
    }

    // MARK: - 表示

    /// - Parameter symbolName: 入力欄の左に置く SF Symbol。今どのモードかを示す。
    func present(placeholder: String, symbolName: String, candidates: [Candidate]) {
        input.stringValue = ""
        // **プレースホルダは控えめにする。** 本文と同じ強さだと、まだ何も打って
        // いないのに入力済みのように見える。
        input.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: Metrics.inputFont,
            ]
        )
        symbolView.image = Metrics.symbol(named: symbolName)
        table.setCandidates(candidates, matching: "")
        layout()

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
    }

    func dismiss() {
        panel.orderOut(nil)
        table.setCandidates([], matching: "")
        input.stringValue = ""
    }

    /// - Parameters:
    ///   - query: マッチした文字を太らせるために照合する入力。キーワードを外した
    ///     ぶんを渡す（`f report` なら `report`）。
    ///   - status: 候補が無いときに 1 行だけ出す文言。
    func setCandidates(_ candidates: [Candidate], matching query: String, status: String? = nil) {
        table.setCandidates(candidates, matching: query, status: status)
        layout()
    }

    /// 入力欄に文字を流し込む。`--show-search` での動作確認に使う。
    ///
    /// **カーソルは末尾に置く。** `stringValue` を入れただけだと field editor が
    /// 全選択の状態になり、続けて打った 1 文字で消える。
    func setQuery(_ text: String) {
        input.stringValue = text
        if let editor = panel.fieldEditor(false, for: input) as? NSTextView {
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }

    // MARK: - 配置

    /// **常にメインディスプレイに出す。** マウス位置やフォーカスには追従しない
    /// （requirements.md 3.2）。`NSScreen.main` はキーウィンドウのある画面を返すので、
    /// メニューバーを持つ画面（`screens.first`）を使う。
    private func layout() {
        let area = NSScreen.screens.first?.visibleFrame

        // **画面から出ないように行数を抑える。** `max_results` は 50 まで許して
        // いるので、そのまま使うと候補が画面の下へ突き抜けて選べない。
        // **メソッド参照ではなくクロージャで渡す。** `@MainActor` のメソッドを
        // 関数値として渡せるのは Swift 6.1 以降で、6.0 では弾かれる。
        let rows = min(
            table.count, maxVisibleRows, area.map { Self.rowsThatFit(in: $0) } ?? maxVisibleRows)

        let listHeight = rows > 0 ? CGFloat(rows) * Metrics.rowHeight : 0
        let separatorSpace = rows > 0 ? Metrics.separatorThickness : 0

        separator.isHidden = rows == 0
        table.isHidden = rows == 0
        separatorHeight?.constant = separatorSpace
        tableHeight?.constant = listHeight

        // 制約で決まる内容の高さと同じ値を使う。ここがずれると入力欄が切れる。
        let height = Metrics.inputHeight + separatorSpace + listHeight

        guard let area else {
            panel.setContentSize(NSSize(width: panel.frame.width, height: height))
            return
        }

        let width = panel.frame.width
        let x = area.midX - width / 2
        // 上端を固定して下へ伸ばす。候補が増えても入力欄が動かない。
        let top = area.maxY - area.height * Self.verticalInset
        panel.setFrame(
            NSRect(x: x.rounded(), y: (top - height).rounded(), width: width, height: height),
            display: true
        )

        // 見た目は数値でしか確かめられないので残す。
        log.debug(
            "窓: 幅=\(Int(width)) 高さ=\(Int(height)) 行=\(rows)"
                + " 入力欄=\(Int(Metrics.inputHeight)) 行高=\(Int(Metrics.rowHeight))"
                + " 文字左端=\(Int(Metrics.textInset))"
        )
    }

    /// 上端を固定したまま画面に収まる行数。テストから呼べるように internal。
    static func rowsThatFit(in area: NSRect) -> Int {
        let available =
            area.height * (1 - verticalInset) - Metrics.inputHeight
            - Metrics.separatorThickness - bottomMargin
        return max(1, Int(available / Metrics.rowHeight))
    }

    // MARK: - 組み立て

    private func build() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // 全画面アプリの上にも出す。
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false

        // **`.popover` より濃い `.hudWindow` を使う。** 背景が透けすぎると
        // 文字のコントラストが下がって読みにくい。
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = Metrics.cornerRadius
        container.layer?.masksToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false

        // 入力に目を向けたいので、アイコンは控えめな色にする。
        symbolView.contentTintColor = .secondaryLabelColor
        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.translatesAutoresizingMaskIntoConstraints = false

        // **light は使わない。** この大きさでは細すぎて輪郭がぼやける。
        input.font = Metrics.inputFont
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.usesSingleLineMode = true
        input.lineBreakMode = .byTruncatingTail
        input.delegate = self
        // 残りの幅は入力欄が取る。
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        table.translatesAutoresizingMaskIntoConstraints = false
        table.onActivate = { [weak self] in self?.onSubmit?() }

        // **アイコンと文字は StackView で縦中央を揃える。** 別々に制約を張ると、
        // `NSTextField` のテキストが枠の中で寄って中心がずれる（実機でアイコンだけ
        // 上に浮いて見えた）。
        let inputRow = NSStackView(views: [symbolView, input])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = Metrics.iconGap
        inputRow.edgeInsets = NSEdgeInsets(
            top: 0, left: Metrics.horizontalPadding, bottom: 0,
            right: Metrics.horizontalPadding)
        inputRow.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(inputRow)
        container.addSubview(separator)
        container.addSubview(table)

        // **初期値は候補が無いときの値（0）にする。** panel は `inputHeight` で
        // 作られるので、線の分を先に要求すると `layout()` が走るまで食い違う。
        let separatorHeight = separator.heightAnchor.constraint(equalToConstant: 0)
        let tableHeight = table.heightAnchor.constraint(equalToConstant: 0)
        self.separatorHeight = separatorHeight
        self.tableHeight = tableHeight

        NSLayoutConstraint.activate([
            inputRow.topAnchor.constraint(equalTo: container.topAnchor),
            inputRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            inputRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            inputRow.heightAnchor.constraint(equalToConstant: Metrics.inputHeight),

            // 候補のアイコンと同じ幅を確保する。ここが揃わないと文字の左端もずれる。
            symbolView.widthAnchor.constraint(equalToConstant: Metrics.iconWidth),
            symbolView.heightAnchor.constraint(equalToConstant: Metrics.iconWidth),

            separator.topAnchor.constraint(equalTo: inputRow.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separatorHeight,

            table.topAnchor.constraint(equalTo: separator.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tableHeight,
        ])

        panel.contentView = container

        // 他のアプリへ移ったら閉じる（requirements.md 3.2）。
        //
        // **NotificationCenter ではなく delegate で受ける。** `NSWindow.delegate` は
        // 弱参照なので、外し忘れて登録が残ることがない（block observer は自分で
        // 外す必要があり、`@MainActor` のクラスの `deinit` からは外せない）。
        panel.delegate = self
    }

    // MARK: - NSWindowDelegate

    /// 他のアプリへ移った。
    ///
    /// **自分で閉じたときは無視する。** `orderOut` でも key を手放すので、
    /// 表示中かどうかで区別しないと `dismiss` が二重に走る。
    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        onResignKey?()
    }

    // MARK: - キー操作

    func controlTextDidChange(_ notification: Notification) {
        onQueryChange?(input.stringValue)
    }

    /// 一覧を動かすキーを捕まえる。
    ///
    /// これらは field editor が先に受け取るため、`NSPanel` の `keyDown` では届かない。
    ///
    /// | キー | 届く selector | 動き |
    /// |---|---|---|
    /// | `Esc` | `cancelOperation` | 閉じる |
    /// | `Enter` | `insertNewline` | 実行 |
    /// | `↑` `↓` / `^P` `^N` | `moveUp` `moveDown` | 1 つ動かす |
    /// | `PageUp` `PageDown` | `scrollPageUp` `scrollPageDown` | 1 画面動かす |
    /// | `Home` `End` | `scrollTo…OfDocument` | 端へ飛ぶ |
    /// | `⌘↑` `⌘↓` | `moveTo…OfDocument` | 端へ飛ぶ |
    ///
    /// `^P` / `^N` は AppKit の既定のキーバインドが `moveUp:` / `moveDown:` へ
    /// 変換するので、ここで個別に見る必要はない。
    ///
    /// **捕まえたものだけ true を返す。** それ以外を true にすると文字が打てなくなる。
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?()
        case #selector(NSResponder.moveDown(_:)):
            table.moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            table.moveSelection(by: -1)
        case #selector(NSResponder.scrollPageDown(_:)):
            table.moveSelectionByPage(1)
        case #selector(NSResponder.scrollPageUp(_:)):
            table.moveSelectionByPage(-1)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)),
            #selector(NSResponder.scrollToBeginningOfDocument(_:)):
            table.moveSelectionToEdge(.first)
        case #selector(NSResponder.moveToEndOfDocument(_:)),
            #selector(NSResponder.scrollToEndOfDocument(_:)):
            table.moveSelectionToEdge(.last)
        default:
            return false
        }
        return true
    }
}
