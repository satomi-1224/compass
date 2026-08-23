import AppKit
import CompassCore

/// 候補を並べる表。
///
/// **フォーカスを受け取らない**（`refusesFirstResponder`）。選択は入力欄に置いた
/// まま矢印キーで動かす。表がフォーカスを奪うと文字が打てなくなる。
///
/// 候補が 1 件も無いときは、状態を 1 行だけ出す（「探しています…」「一致するものが
/// ない」）。**この行は選べない。** 窓が入力欄だけに縮むと、絞り込めていないのか
/// 探している最中なのかが区別できない。
@MainActor
final class CandidateTable: NSView {

    static var rowHeight: CGFloat { Metrics.rowHeight }

    /// ダブルクリックで実行された。
    var onActivate: (() -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var candidates: [Candidate] = []
    /// 候補と照らし合わせる入力。マッチした文字を太らせるのに使う。
    private var query = ""
    /// 候補が無いときに 1 行だけ出す文言。
    private var status: String?

    /// 表に出す行数。**候補が無いときの状態行を含む。**
    var count: Int { candidates.isEmpty ? (status == nil ? 0 : 1) : candidates.count }

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

    /// - Parameters:
    ///   - query: マッチした文字を太らせるために照合する入力。キーワードを外した
    ///     ぶんを渡す（`f report` なら `report`）。
    ///   - status: 候補が無いときに出す文言。nil なら何も出さない。
    func setCandidates(_ newValue: [Candidate], matching query: String, status: String? = nil) {
        candidates = newValue
        self.query = query
        self.status = status
        tableView.reloadData()
        guard !newValue.isEmpty else { return }
        // 常に先頭を選ぶ。前回の選択位置を引き継ぐと、絞り込むたびに
        // 意図しない候補が実行される。
        tableView.selectRowIndexes([0], byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
        refreshSelectionAppearance()
    }

    /// 選択を 1 つずつ動かす。**端で止める。**
    func moveSelection(by delta: Int) {
        guard !candidates.isEmpty else { return }
        // 巻き戻すと押し続けたときの行き先が読めない。
        select(tableView.selectedRow + delta)
    }

    /// 先頭・末尾へ飛ぶ。`Cmd+↑` / `Cmd+↓` と `Home` / `End`。
    func moveSelectionToEdge(_ edge: Edge) {
        guard !candidates.isEmpty else { return }
        select(edge == .first ? 0 : candidates.count - 1)
    }

    enum Edge { case first, last }

    /// 見えている行数ぶん飛ぶ。`PageUp` / `PageDown`。
    ///
    /// **1 行ぶん重ねる。** 飛んだ先が前の画面と地続きだと分かるようにする。
    func moveSelectionByPage(_ direction: Int) {
        guard !candidates.isEmpty else { return }
        let visible = max(1, Int(scrollView.contentView.bounds.height / Metrics.rowHeight) - 1)
        select(tableView.selectedRow + direction * visible)
    }

    private func select(_ row: Int) {
        let next = min(max(row, 0), candidates.count - 1)
        tableView.selectRowIndexes([next], byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
        refreshSelectionAppearance()
    }

    /// 選択に合わせて文字とシンボルの色を切り替える。
    ///
    /// **`backgroundStyle` には頼れない。** `refusesFirstResponder = true` のため
    /// 表が first responder にならず `isEmphasized` が立たないので、
    /// `.emphasized` が渡ってこない。ダークモードでは `labelColor` が白なので
    /// 偶然読めていたが、ライトモードでは濃い青地に黒文字になる。
    private func refreshSelectionAppearance() {
        for row in 0..<tableView.numberOfRows {
            let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
            (view as? CandidateRowView)?.setSelected(tableView.selectedRow == row)
        }
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
        // 状態行はダブルクリックしても何も起きない。
        guard selected != nil else { return }
        onActivate?()
    }
}

// MARK: - データ

extension CandidateTable: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("row")
        let view =
            tableView.makeView(withIdentifier: identifier, owner: self) as? CandidateRowView
            ?? CandidateRowView()
        view.identifier = identifier

        guard candidates.indices.contains(row) else {
            view.configure(status: status ?? "")
            return view
        }
        view.configure(
            with: candidates[row], matching: query, selected: tableView.selectedRow == row)
        return view
    }

    /// 状態行は選べない。選べてしまうと `Enter` の行き先が無いのに反応する。
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        candidates.indices.contains(row)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshSelectionAppearance()
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
@MainActor
private final class CandidateRowView: NSTableCellView {

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    /// アプリのアイコンは色を変えない。シンボルだけ選択に合わせて塗り替える。
    private var usesSymbol = false
    /// 状態行は選択の色分けをしない。
    private var isStatus = false
    /// 現在のタイトルとマッチ位置。選択が変わるたびに組み直すために持つ。
    private var title = ""
    private var matched: [Int] = []

    init() {
        super.init(frame: .zero)

        // **拡大させない。** `Metrics.symbolPointSize` で決めた大きさを保つ。
        // 上げ幅を許すと、入力欄のシンボルと候補のシンボルで太さが変わって見える。
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Metrics.titleFont
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true

        // パスは末尾のほうが手がかりになる。中間を省く。
        subtitleLabel.font = Metrics.subtitleFont
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.usesSingleLineMode = true

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

        setSelected(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Interface Builder からは使わない")
    }

    func configure(with candidate: Candidate, matching query: String, selected: Bool) {
        isStatus = false
        title = candidate.title
        // **別名で当たった場合は位置が取れない。** その場合は太らせない
        // （`sys` で「システム設定」が出たときに、無関係な字が太るのを避ける）。
        matched = FuzzyMatcher.score(query, in: candidate.title)?.positions ?? []

        subtitleLabel.stringValue = candidate.subtitle ?? ""
        subtitleLabel.isHidden = candidate.subtitle == nil

        switch candidate.icon {
        case .file(let path):
            iconView.image = NSWorkspace.shared.icon(forFile: path)
            iconView.contentTintColor = nil
            usesSymbol = false
        case .symbol(let name):
            iconView.image = Metrics.symbol(named: name)
            usesSymbol = true
        }

        setSelected(selected)
    }

    /// 候補が無いときの 1 行。**選択の色は付けない。**
    func configure(status: String) {
        isStatus = true
        title = status
        matched = []
        subtitleLabel.stringValue = ""
        subtitleLabel.isHidden = true
        iconView.image = nil
        usesSymbol = false
        setSelected(false)
    }

    /// 選択されると背景が濃くなる。文字とシンボルの色を合わせないと読めない。
    func setSelected(_ selected: Bool) {
        let color: NSColor =
            isStatus
            ? .tertiaryLabelColor
            : (selected ? .alternateSelectedControlTextColor : .labelColor)
        titleLabel.attributedStringValue = Self.attributedTitle(
            title, matched: matched, color: color)
        subtitleLabel.textColor =
            selected
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8)
            : .secondaryLabelColor
        if usesSymbol {
            iconView.contentTintColor =
                selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }

    /// マッチした文字だけ太らせる。
    ///
    /// **色は変えない。** 選択行は濃い地の上に載るので、色差だと沈むか浮きすぎる。
    /// 太さの差なら地の色に関係なく読み取れる。
    private static func attributedTitle(
        _ title: String, matched: [Int], color: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: title,
            attributes: [.font: Metrics.titleFont, .foregroundColor: color]
        )
        guard !matched.isEmpty else { return result }

        // `matched` は Character 単位の位置。NSAttributedString は UTF-16 単位なので
        // **数え直す。** 絵文字や結合文字を含む名前でずれる。
        let positions = Set(matched)
        var offset = 0
        for (index, character) in title.enumerated() {
            let length = character.utf16.count
            if positions.contains(index) {
                result.addAttribute(
                    .font, value: Metrics.titleMatchFont,
                    range: NSRange(location: offset, length: length))
            }
            offset += length
        }
        return result
    }
}
