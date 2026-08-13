import AppKit
import CompassCore

/// 候補を並べる表。
///
/// **フォーカスを受け取らない**（`refusesFirstResponder`）。選択は入力欄に置いた
/// まま矢印キーで動かす。表がフォーカスを奪うと文字が打てなくなる。
@MainActor
final class CandidateTable: NSView {

    static var rowHeight: CGFloat { Metrics.rowHeight }

    /// ダブルクリックで実行された。
    var onActivate: (() -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var candidates: [Candidate] = []

    var count: Int { candidates.count }

    var selected: Candidate? {
        let row = tableView.selectedRow
        guard candidates.indices.contains(row) else { return nil }
        return candidates[row]
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Interface Builder からは使わない")
    }

    // MARK: - 候補の差し替え

    func setCandidates(_ newValue: [Candidate]) {
        candidates = newValue
        tableView.reloadData()
        guard !newValue.isEmpty else { return }
        // 常に先頭を選ぶ。前回の選択位置を引き継ぐと、絞り込むたびに
        // 意図しない候補が実行される。
        tableView.selectRowIndexes([0], byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
    }

    func moveSelection(by delta: Int) {
        guard !candidates.isEmpty else { return }
        // **端で止める。** 巻き戻すと押し続けたときの行き先が読めない。
        let next = min(max(tableView.selectedRow + delta, 0), candidates.count - 1)
        tableView.selectRowIndexes([next], byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: - 組み立て

    private func build() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("candidate"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Metrics.rowHeight
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        // 入力欄からフォーカスを奪わせない。
        tableView.refusesFirstResponder = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func handleDoubleClick() {
        onActivate?()
    }
}

// MARK: - データ

extension CandidateTable: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard candidates.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("row")
        let view =
            tableView.makeView(withIdentifier: identifier, owner: self) as? CandidateRowView
            ?? CandidateRowView()
        view.identifier = identifier
        view.configure(with: candidates[row])
        return view
    }

    /// 角丸のハイライトを描くために差し替える。
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("rowBackground")
        if let existing = tableView.makeView(withIdentifier: identifier, owner: self)
            as? RoundedRowView
        {
            return existing
        }
        let view = RoundedRowView()
        view.identifier = identifier
        return view
    }
}

/// 選択を角丸で塗る行。
///
/// 既定の矩形ハイライトは窓の角丸と噛み合わず、端で角が飛び出して見える。
@MainActor
private final class RoundedRowView: NSTableRowView {

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let area = bounds.insetBy(
            dx: Metrics.selectionInset, dy: Metrics.selectionVerticalInset)
        let path = NSBezierPath(
            roundedRect: area, xRadius: Metrics.selectionRadius,
            yRadius: Metrics.selectionRadius)
        NSColor.selectedContentBackgroundColor.setFill()
        path.fill()
    }
}

/// 1 行の見た目。アイコン + タイトル + サブタイトル。
///
/// `NSTableCellView` を継承しているのは `backgroundStyle` を受け取るため。
/// 選択されたときに文字色を切り替えないと、青地に黒文字で読めなくなる。
@MainActor
private final class CandidateRowView: NSTableCellView {

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    /// アプリのアイコンは色を変えない。シンボルだけ選択に合わせて塗り替える。
    private var usesSymbol = false

    init() {
        super.init(frame: .zero)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Metrics.titleFont
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true
        titleLabel.textColor = .labelColor

        // パスは末尾のほうが手がかりになる。中間を省く。
        subtitleLabel.font = Metrics.subtitleFont
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.usesSingleLineMode = true
        subtitleLabel.textColor = .secondaryLabelColor

        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Metrics.titleSpacing
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(text)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Metrics.horizontalPadding),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.iconWidth),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.iconWidth),

            // **入力欄と同じ位置から文字を始める**（Metrics.textInset）。
            text.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Metrics.textInset),
            text.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Metrics.horizontalPadding),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Interface Builder からは使わない")
    }

    func configure(with candidate: Candidate) {
        titleLabel.stringValue = candidate.title
        subtitleLabel.stringValue = candidate.subtitle ?? ""
        subtitleLabel.isHidden = candidate.subtitle == nil

        switch candidate.icon {
        case .file(let path):
            iconView.image = NSWorkspace.shared.icon(forFile: path)
            iconView.contentTintColor = nil
            usesSymbol = false
        case .symbol(let name):
            iconView.image = Metrics.symbol(named: name)
            iconView.contentTintColor = .secondaryLabelColor
            usesSymbol = true
        }
    }

    /// 選択されると背景が濃くなる。文字色とシンボルの色を合わせないと読めない。
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            titleLabel.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
            subtitleLabel.textColor =
                emphasized
                ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8)
                : .secondaryLabelColor
            if usesSymbol {
                iconView.contentTintColor =
                    emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
            }
        }
    }
}
