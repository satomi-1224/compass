import Foundation
import Testing

@testable import CompassCore

@MainActor
@Suite("ConfigStore")
struct ConfigStoreTests {

    /// 通知を出さずに記録するだけの伝え先。
    final class Recorder: IssueReporting {
        var issues: [ConfigIssue] = []
        var messages: [(title: String, body: String)] = []

        func report(_ issues: [ConfigIssue]) { self.issues.append(contentsOf: issues) }
        func report(title: String, body: String) { messages.append((title, body)) }
    }

    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("compass-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to directory: URL, as file: ConfigFile) throws {
        try text.write(
            to: directory.appendingPathComponent(file.fileName),
            atomically: true,
            encoding: .utf8
        )
    }

    private func remove(_ file: ConfigFile, from directory: URL) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(file.fileName))
    }

    // MARK: - 読み込み

    /// ファイル欠損はエラーにしない（requirements.md 5.4）。
    @Test("ファイルが無ければ既定値になり、通知も出さない")
    func missingFilesAreNotErrors() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = Recorder()
        let store = ConfigStore(directory: directory, reporter: recorder)
        let issues = store.load()

        #expect(issues.isEmpty)
        #expect(recorder.issues.isEmpty)
        #expect(store.config == Config())
        #expect(store.snippets.isEmpty)
        // 検索窓は設定が無くても使える。
        #expect(store.hotkeys.bindings.contains { $0.action == .builtin(.search) })
    }

    @Test("3 ファイルを読み込む")
    func loadsAllThreeFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try write("[clipboard]\nmax_items = 12", to: directory, as: .config)
        try write(#"[commands]\#nt = "open -a WezTerm""#, to: directory, as: .hotkeys)
        try write(#"[[snippets]]\#ntitle = "now"\#nbody = "x""#, to: directory, as: .snippets)

        let recorder = Recorder()
        let store = ConfigStore(directory: directory, reporter: recorder)
        let issues = store.load()

        #expect(issues.isEmpty)
        #expect(store.config.clipboard.maxItems == 12)
        #expect(store.hotkeys.bindings.contains { $0.key == "t" })
        #expect(store.snippets.map(\.title) == ["now"])
    }

    /// **設定を壊してもランチャーが死んではいけない**（requirements.md 5.4）。
    @Test("壊れた設定は直前の内容を保ったまま通知する")
    func keepsLastGoodConfiguration() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = Recorder()
        let store = ConfigStore(directory: directory, reporter: recorder)

        try write("[clipboard]\nmax_items = 12", to: directory, as: .config)
        store.load()
        #expect(store.config.clipboard.maxItems == 12)

        // 範囲外の値に書き換える。
        try write("[clipboard]\nmax_items = 0", to: directory, as: .config)
        let issues = store.load()

        #expect(!issues.isEmpty)
        #expect(recorder.issues.count == issues.count)
        // 直前の値が残っている。
        #expect(store.config.clipboard.maxItems == 12)
    }

    @Test("壊れたファイル以外は差し替わる")
    func healthyFilesStillLoad() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConfigStore(directory: directory, reporter: Recorder())

        // config.toml だけ壊れている。
        try write("[appearance", to: directory, as: .config)
        try write(#"[commands]\#nt = "open -a WezTerm""#, to: directory, as: .hotkeys)
        let issues = store.load()

        #expect(issues.allSatisfy { $0.file == .config })
        #expect(store.hotkeys.bindings.contains { $0.key == "t" })
    }

    @Test("ファイルが消えたら既定に戻る")
    func removalResetsToDefault() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConfigStore(directory: directory, reporter: Recorder())

        try write("[clipboard]\nmax_items = 12", to: directory, as: .config)
        store.load()
        #expect(store.config.clipboard.maxItems == 12)

        try remove(.config, from: directory)
        let issues = store.load()

        #expect(issues.isEmpty)
        #expect(store.config == Config())
    }

    // MARK: - 変更の通知

    @Test("内容が変わらなければ onChange を呼ばない")
    func onChangeOnlyOnRealChange() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConfigStore(directory: directory, reporter: Recorder())
        var changes = 0
        store.onChange = { changes += 1 }

        try write("[clipboard]\nmax_items = 12", to: directory, as: .config)
        store.load()
        #expect(changes == 1)

        // 同じ内容で読み直しても呼ばれない（ホットキーの無用な再登録を避ける）。
        store.load()
        #expect(changes == 1)

        try write("[clipboard]\nmax_items = 13", to: directory, as: .config)
        store.load()
        #expect(changes == 2)
    }

    @Test("エラーで内容が変わらなければ onChange を呼ばない")
    func onChangeNotCalledOnError() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConfigStore(directory: directory, reporter: Recorder())

        try write("[clipboard]\nmax_items = 12", to: directory, as: .config)
        store.load()

        var changes = 0
        store.onChange = { changes += 1 }

        try write("[clipboard]\nmax_items = 0", to: directory, as: .config)
        store.load()
        #expect(changes == 0)
    }

    // MARK: - 監視

    @Test("設定ディレクトリがあれば監視を張れる")
    func startsWatching() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConfigStore(directory: directory, reporter: Recorder())
        #expect(store.startWatching())
        store.stopWatching()
    }

    /// 初回起動では設定ディレクトリがまだ無い。親を見て作成を待つ。
    @Test("設定ディレクトリが無くても親を監視して待つ")
    func watchesParentUntilDirectoryAppears() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("compass-absent-\(UUID().uuidString)", isDirectory: true)
        let store = ConfigStore(directory: missing, reporter: Recorder())
        #expect(store.startWatching())
        store.stopWatching()
    }

    /// 失敗した watcher を残すと、以後 guard に弾かれて何も監視しないまま
    /// 「張れている」と答え続ける。
    @Test("監視に失敗しても、状況が変われば張り直せる")
    func canRetryAfterFailure() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("compass-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // 親ごと存在しないので、どこも監視できない。
        let directory = base.appendingPathComponent("compass", isDirectory: true)
        let store = ConfigStore(directory: directory, reporter: Recorder())
        #expect(store.startWatching() == false)

        // 親ができれば張れるようになる。失敗した watcher が残っていれば true を
        // 返せないまま何も監視しない。
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        #expect(store.startWatching())
        store.stopWatching()
    }
}
