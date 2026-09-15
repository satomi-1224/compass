import Foundation

/// 設定ディレクトリの変更を監視する。
///
/// **ディレクトリと個々のファイルの両方を見る。** 片方だけでは取りこぼす。
///
/// | 変更の仕方 | 観測できる場所 |
/// |---|---|
/// | エディタが上書き保存する（内容だけ変わる） | **ファイル**への書き込み |
/// | 一時ファイルを作って rename する（vim の既定など） | **ディレクトリ**への書き込み |
/// | home-manager がファイル単位のシンボリックリンクを張り替える | **ディレクトリ**への書き込み |
/// | ディレクトリ自体がシンボリックリンクで張り替えられる | **親ディレクトリ**への書き込み |
///
/// ファイルの fd だけを掴んでいると、張り替えられた後は古い inode を見続けて以後の
/// 変更に気づけない。ディレクトリの変更を受けたらファイルの監視も張り直す。
///
/// `open` はシンボリックリンクを追うため、**設定ディレクトリ自体がリンクだと
/// 張り替えても古い実体を見続ける。** その場合と、ディレクトリがまだ無い場合は
/// 親、または最も近い存在する祖先を見て復帰する。
@MainActor
public final class ConfigWatcher {

    public var onChange: (@MainActor () -> Void)?

    private let directory: String
    private let parentDirectory: String
    private let fileNames: [String]
    private let debounce: TimeInterval
    private let log: Log

    // 掴んだ `O_EVTONLY` の fd は cancel handler が閉じる。`ManagedSource` に
    // 入れておくと、参照を捨てた時点で必ず cancel されるので、`stop()` を
    // 呼び忘れても fd がプロセスの寿命まで残らない。
    private var directorySource: ManagedSource?
    private var fileSources: [String: ManagedSource] = [:]
    private var parentSource: ManagedSource?
    /// debounce 待ちの通知。**self を強く捕まえる**ので、待っている間は
    /// ConfigWatcher が解放されない。片付けの対象にしなくてよい。
    private var pending: DispatchWorkItem?

    /// - Parameter debounce: 保存ソフトは 1 回の保存で複数回書き込む。まとめてから通知する。
    public init(
        directory: String,
        fileNames: [String],
        debounce: TimeInterval = 0.3,
        log: Log = .shared
    ) {
        self.directory = directory
        self.parentDirectory = (directory as NSString).deletingLastPathComponent
        self.fileNames = fileNames
        self.debounce = debounce
        self.log = log
    }

    public var isWatching: Bool {
        directorySource != nil || parentSource != nil || !fileSources.isEmpty
    }

    /// 実体のあるファイルをいくつ掴めているか。ファイルが無い間は 0。
    public var watchedFileCount: Int { fileSources.count }

    /// 設定ディレクトリ自体を掴めているか。
    public var isWatchingDirectory: Bool { directorySource != nil }

    /// 親ディレクトリを見ているか。ディレクトリが無い、またはディレクトリ自体が
    /// シンボリックリンクのときだけ true になる。
    public var isWatchingParent: Bool { parentSource != nil }

    /// 監視を始める。
    ///
    /// - Returns: どこか 1 つでも監視できたか。設定ディレクトリが無くても、
    ///   親を見て作成を待てるなら true。
    @discardableResult
    public func start() -> Bool {
        watchDirectory()
        for name in fileNames { watchFile(name) }
        syncParentWatch()

        if isWatching {
            log.debug("設定の変更を監視: \(directory)")
        } else {
            log.warn("設定ディレクトリもその祖先も監視できない: \(directory)")
        }
        return isWatching
    }

    /// 監視を止める。**参照を捨てるだけ**で `ManagedSource` が cancel する。
    public func stop() {
        pending?.cancel()
        pending = nil
        parentSource = nil
        directorySource = nil
        fileSources.removeAll()
    }

    // MARK: - 監視の設置

    private func watchDirectory() {
        guard directorySource == nil else { return }
        directorySource = makeSource(for: directory, mask: [.write, .rename, .delete]) {
            [weak self] events in
            guard let self else { return }

            if events.contains(.delete) || events.contains(.rename) {
                // ディレクトリ自体が消えた・付け替えられた。掴んでいる fd は使えない。
                //
                // **張り直しは debounce に載せない。** debounce の枠は 1 つしかないため、
                // 直後にファイル側のイベントが来ると復帰処理ごと取り消され、以後
                // ディレクトリ監視が永久に失われる。
                self.log.debug("設定ディレクトリが差し替えられた。監視を張り直す")
                self.rewatchAll()
            } else {
                // 中身が変わった。ファイルが差し替えられた可能性があるので張り直す。
                for name in self.fileNames { self.rewatchFile(name) }
            }
            self.schedule { self.onChange?() }
        }
    }

    private func watchFile(_ name: String) {
        guard fileSources[name] == nil else { return }
        let path = "\(directory)/\(name)"
        guard FileManager.default.fileExists(atPath: path) else { return }

        fileSources[name] = makeSource(for: path, mask: [.write, .rename, .delete, .extend]) {
            [weak self] events in
            guard let self else { return }
            if events.contains(.delete) || events.contains(.rename) {
                self.rewatchFile(name)
            }
            self.schedule { self.onChange?() }
        }
    }

    private func rewatchFile(_ name: String) {
        fileSources[name] = nil
        watchFile(name)
    }

    /// 監視を全て張り直す。ディレクトリが差し替えられたときに使う。
    private func rewatchAll() {
        directorySource = nil
        fileSources.removeAll()
        // 欠けている階層が 1 つ作られた場合、次はその階層を監視したい。古い祖先の
        // source を残すと guard に止められ、さらに下の作成を検知できない。
        parentSource = nil

        watchDirectory()
        for name in fileNames { watchFile(name) }
        syncParentWatch()
    }

    // MARK: - 親ディレクトリ

    /// 設定ディレクトリを直接見るだけでは足りない状況か。
    ///
    /// - ディレクトリがまだ無い（初回起動、差し替えの途中）
    /// - **ディレクトリ自体がシンボリックリンク。** `open` はリンク先を開くため、
    ///   リンクを張り替えても古い実体を見続けて変更に気づけない
    private var needsParentWatch: Bool {
        // `attributesOfItem` はリンクを追わないので、リンク自体の型が分かる。
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: directory) else {
            return true
        }
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// 親ディレクトリの監視を、必要な状態に合わせる。
    ///
    /// プラグイン設定は `.../compass/plugins/` と 1 階層深い。初回起動時に
    /// `compass/` ごと無くても、存在する祖先まで上って作成を待つ。
    private func syncParentWatch() {
        guard needsParentWatch else {
            parentSource = nil
            return
        }
        guard parentSource == nil else { return }

        var candidate = parentDirectory
        while !candidate.isEmpty {
            if let source = makeSource(
                for: candidate,
                mask: [.write],
                handler: { [weak self] _ in
                    guard let self else { return }
                    // 設定ディレクトリへ続く階層が作られた・張り替えられたかもしれない。
                    self.rewatchAll()
                    self.schedule { self.onChange?() }
                }
            ) {
                parentSource = source
                return
            }

            let next = (candidate as NSString).deletingLastPathComponent
            guard next != candidate else { break }
            candidate = next
        }
    }

    // MARK: - 共通

    private func makeSource(
        for path: String,
        mask: DispatchSource.FileSystemEvent,
        handler: @escaping @MainActor (DispatchSource.FileSystemEvent) -> Void
    ) -> ManagedSource? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setEventHandler { [weak source] in
            MainActor.assumeIsolated {
                handler(source?.data ?? [])
            }
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        source.resume()
        return ManagedSource(source)
    }

    /// 保存ソフトは 1 回の保存で複数回書き込む。まとめてから通知する。
    ///
    /// **この枠に監視の張り直しを載せてはいけない。** 後続のイベントで取り消される。
    private func schedule(_ body: @escaping @MainActor () -> Void) {
        pending?.cancel()
        let item = DispatchWorkItem {
            MainActor.assumeIsolated {
                body()
            }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
