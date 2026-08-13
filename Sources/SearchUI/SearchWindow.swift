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
@MainActor
final class SearchWindow: NSObject, NSTextFieldDelegate {

    /// 入力が変わった。
    var onQueryChange: ((String) -> Void)?
    /// `Enter` が押された。
    var onSubmit: (() -> Void)?
    /// `Esc`、または他のアプリへ移ったので閉じるべき。
    var onCancel: (() -> Void)?

    private static let inputHeight: CGFloat = 48
    private static let cornerRadius: CGFloat = 12
    private static let separatorThickness: CGFloat = 1
    /// 画面の上端からどれだけ下げるか。上寄り中央に出す（requirements.md 3.2）。
    private static let verticalInset: CGFloat = 0.18
    /// 画面の下端に残す余白。ぴったり接すると見づらい。
    private static let bottomMargin: CGFloat = 20

    private let panel: KeyablePanel
    private let input = NSTextField()
    private let separator = NSBox()
    private let table = CandidateTable()
    private let container = NSVisualEffectView()
    private let maxVisibleRows: Int

    /// 高さは制約で決める。**隠すだけでは制約が残り、内容の高さと panel の高さが
    /// 食い違って入力欄の上端が切れる**（実測で 48pt の窓に 49pt の内容が入った）。
    private var separatorHeight: NSLayoutConstraint?
    private var tableHeight: NSLayoutConstraint?
    private var resignObserver: NSObjectProtocol?

    init(width: CGFloat, maxVisibleRows: Int) {
        self.maxVisibleRows = max(1, maxVisibleRows)
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: Self.inputHeight),
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

    func present(placeholder: String, candidates: [Candidate]) {
        input.stringValue = ""
        input.placeholderString = placeholder
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
        // いるので、そのまま使うと候補が画面の下へ突き抜けて選べない
        // （20 行で 929pt、50 行で 2249pt になる）。
        let rows = min(table.count, maxVisibleRows, area.map(Self.rowsThatFit) ?? maxVisibleRows)

        let listHeight = rows > 0 ? CGFloat(rows) * CandidateTable.rowHeight : 0
        let separatorSpace = rows > 0 ? Self.separatorThickness : 0

        separator.isHidden = rows == 0
        table.isHidden = rows == 0
        separatorHeight?.constant = separatorSpace
        tableHeight?.constant = listHeight

        // 制約で決まる内容の高さと同じ値を使う。ここがずれると入力欄が切れる。
        let height = Self.inputHeight + separatorSpace + listHeight

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
    }

    /// 上端を固定したまま画面に収まる行数。テストから呼べるように internal。
    static func rowsThatFit(in area: NSRect) -> Int {
        let available =
            area.height * (1 - verticalInset) - inputHeight - separatorThickness - bottomMargin
        return max(1, Int(available / CandidateTable.rowHeight))
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

        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = Self.cornerRadius
        container.layer?.masksToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false

        input.font = .systemFont(ofSize: 22, weight: .light)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.delegate = self
        input.translatesAutoresizingMaskIntoConstraints = false

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        table.translatesAutoresizingMaskIntoConstraints = false
        table.onActivate = { [weak self] in self?.onSubmit?() }

        container.addSubview(input)
        container.addSubview(separator)
        container.addSubview(table)

        // **初期値は候補が無いときの値（0）にする。** panel は `inputHeight` で
        // 作られるので、1 のままだと `layout()` が走るまで「48pt の窓に 49pt の
        // 内容」という食い違った制約になる。
        let separatorHeight = separator.heightAnchor.constraint(equalToConstant: 0)
        let tableHeight = table.heightAnchor.constraint(equalToConstant: 0)
        self.separatorHeight = separatorHeight
        self.tableHeight = tableHeight

        NSLayoutConstraint.activate([
            input.topAnchor.constraint(equalTo: container.topAnchor),
            input.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            input.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            input.heightAnchor.constraint(equalToConstant: Self.inputHeight),

            separator.topAnchor.constraint(equalTo: input.bottomAnchor),
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
