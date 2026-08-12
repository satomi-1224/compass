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
    /// 画面の上端からどれだけ下げるか。上寄り中央に出す（requirements.md 3.2）。
    private static let verticalInset: CGFloat = 0.18

    private let panel: KeyablePanel
    private let input = NSTextField()
    private let table = CandidateTable()
    private let container = NSVisualEffectView()
    private let maxVisibleRows: Int
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
        let rows = min(table.count, maxVisibleRows)
        let listHeight = rows > 0 ? CGFloat(rows) * CandidateTable.rowHeight + 8 : 0
        let height = Self.inputHeight + listHeight
        table.isHidden = rows == 0

        guard let screen = NSScreen.screens.first else {
            panel.setContentSize(NSSize(width: panel.frame.width, height: height))
            return
        }

        let area = screen.visibleFrame
        let width = panel.frame.width
        let x = area.midX - width / 2
        // 上端を固定して下へ伸ばす。候補が増えても入力欄が動かない。
        let top = area.maxY - area.height * Self.verticalInset
        panel.setFrame(
            NSRect(x: x.rounded(), y: (top - height).rounded(), width: width, height: height),
            display: true
        )
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

        input.font = .systemFont(ofSize: 22, weight: .light)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.delegate = self
        input.translatesAutoresizingMaskIntoConstraints = false
        // 入力中の変換候補が確定するまで通知が来ないと、日本語入力で候補が動かない。
        input.cell?.sendsActionOnEndEditing = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        table.translatesAutoresizingMaskIntoConstraints = false
        table.onActivate = { [weak self] in self?.onSubmit?() }

        container.addSubview(input)
        container.addSubview(separator)
        container.addSubview(table)
        container.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            input.topAnchor.constraint(equalTo: container.topAnchor),
            input.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            input.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            input.heightAnchor.constraint(equalToConstant: Self.inputHeight),

            separator.topAnchor.constraint(equalTo: input.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            table.topAnchor.constraint(equalTo: separator.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
