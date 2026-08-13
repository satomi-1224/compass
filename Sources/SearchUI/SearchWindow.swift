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
/// クリップボード履歴やスニペットのペースト先が変わらない。
///
/// 寸法は `Metrics` に集めてある。**入力欄の左にアイコンを置くのは装飾ではなく、
/// 入力した文字と候補のタイトルの左端を揃えるため。**
@MainActor
final class SearchWindow: NSObject, NSTextFieldDelegate {

    /// 入力が変わった。
    var onQueryChange: ((String) -> Void)?
    /// `Enter` が押された。
    var onSubmit: (() -> Void)?
    /// `Esc`、または他のアプリへ移ったので閉じるべき。
    var onCancel: (() -> Void)?

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
    private var resignObserver: NSObjectProtocol?

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

    isolated deinit {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }

    // MARK: - 状態

    var isVisible: Bool { panel.isVisible }
    var query: String { input.stringValue }
    var selected: Candidate? { table.selected }

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
        table.setCandidates(candidates)
        layout()

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
    }

    func dismiss() {
        panel.orderOut(nil)
        table.setCandidates([])
        input.stringValue = ""
    }

    func setCandidates(_ candidates: [Candidate]) {
        table.setCandidates(candidates)
        layout()
    }

    /// 入力欄に文字を流し込む。`--show-search` での動作確認に使う。
    func setQuery(_ text: String) {
        input.stringValue = text
    }

    // MARK: - 配置

    /// **常にメインディスプレイに出す。** マウス位置やフォーカスには追従しない
    /// （requirements.md 3.2）。`NSScreen.main` はキーウィンドウのある画面を返すので、
    /// メニューバーを持つ画面（`screens.first`）を使う。
    private func layout() {
        let area = NSScreen.screens.first?.visibleFrame

        // **画面から出ないように行数を抑える。** `max_results` は 50 まで許して
        // いるので、そのまま使うと候補が画面の下へ突き抜けて選べない。
        let rows = min(table.count, maxVisibleRows, area.map(Self.rowsThatFit) ?? maxVisibleRows)

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
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.onCancel?()
            }
        }
    }

    // MARK: - キー操作

    func controlTextDidChange(_ notification: Notification) {
        onQueryChange?(input.stringValue)
    }

    /// `Esc` / `↑` / `↓` / `Enter` を捕まえる。
    ///
    /// これらは field editor が先に受け取るため、`NSPanel` の `keyDown` では届かない。
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?()
            return true
        case #selector(NSResponder.moveDown(_:)):
            table.moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            table.moveSelection(by: -1)
            return true
        default:
            return false
        }
    }
}
