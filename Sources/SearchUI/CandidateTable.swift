import AppKit
import CompassCore

/// 候補を並べる表。
///
/// **フォーカスを受け取らない**（`refusesFirstResponder`）。選択は入力欄に置いた
/// まま矢印キーで動かす。表がフォーカスを奪うと文字が打てなくなる。
@MainActor
final class CandidateTable: NSView {

    static let rowHeight: CGFloat = 44

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
        tableView.rowHeight = Self.rowHeight
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
}

/// 1 行の見た目。アイコン + タイトル + パス。
@MainActor
private final class CandidateRowView: NSView {

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)

        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.font = .systemFont(ofSize: 14)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = .labelColor

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.textColor = .secondaryLabelColor

        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [iconView, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
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

        if let path = candidate.iconPath {
            iconView.image = NSWorkspace.shared.icon(forFile: path)
            iconView.isHidden = false
        } else {
            iconView.image = nil
            iconView.isHidden = true
        }
    }
}
