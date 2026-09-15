import Foundation
import Testing

@testable import CompassCore

@MainActor
@Suite("ConfigWatcher")
struct ConfigWatcherTests {

    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("compass-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - どこを見るか

    @Test("実ディレクトリなら直接掴み、親は見ない")
    func watchesDirectoryDirectly() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let watcher = ConfigWatcher(directory: directory.path, fileNames: ["config.toml"])
        #expect(watcher.start())
        #expect(watcher.isWatchingDirectory)
        #expect(watcher.isWatchingParent == false)
        watcher.stop()
    }

    /// `open` はシンボリックリンクを追うため、ディレクトリ自体がリンクだと張り替えても
    /// 古い実体を見続ける。親を見ないと気づけない。
    @Test("ディレクトリがシンボリックリンクなら親も見る")
    func watchesParentWhenDirectoryIsSymlink() throws {
        let base = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let watcher = ConfigWatcher(directory: link.path, fileNames: ["config.toml"])
        #expect(watcher.start())
        #expect(watcher.isWatchingParent)
        watcher.stop()
    }

    @Test("ディレクトリが無ければ親を見る")
    func watchesParentWhenDirectoryMissing() throws {
        let base = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let absent = base.appendingPathComponent("compass", isDirectory: true)
        let watcher = ConfigWatcher(directory: absent.path, fileNames: ["config.toml"])
        #expect(watcher.start())
        #expect(watcher.isWatchingDirectory == false)
        #expect(watcher.isWatchingParent)
        #expect(watcher.watchedFileCount == 0)
        watcher.stop()
    }

    @Test("親も無ければ存在する祖先まで上って段階的に追う")
    func watchesNearestExistingAncestor() async throws {
        let base = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let parent = base.appendingPathComponent("compass", isDirectory: true)
        let directory = parent.appendingPathComponent("plugins", isDirectory: true)
        let watcher = ConfigWatcher(
            directory: directory.path, fileNames: ["snippets.toml"], debounce: 0.05)
        #expect(watcher.start())
        #expect(watcher.isWatchingDirectory == false)
        #expect(watcher.isWatchingParent)

        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(watcher.isWatchingDirectory == false)
        #expect(watcher.isWatchingParent)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(watcher.isWatchingDirectory)
        #expect(watcher.isWatchingParent == false)
        watcher.stop()
    }

    @Test("実体のあるファイルだけを掴む")
    func watchesExistingFilesOnly() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try "a = 1".write(
            to: directory.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let watcher = ConfigWatcher(
            directory: directory.path, fileNames: ["config.toml", "hotkeys.toml"])
        watcher.start()
        #expect(watcher.watchedFileCount == 1)
        watcher.stop()
        #expect(watcher.isWatching == false)
    }

    // MARK: - 検知

    @Test("ファイルの上書き保存を検知する")
    func detectsFileWrite() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("config.toml")
        try "a = 1".write(to: file, atomically: true, encoding: .utf8)

        let watcher = ConfigWatcher(
            directory: directory.path, fileNames: ["config.toml"], debounce: 0.05)
        var fired = 0
        watcher.onChange = { fired += 1 }
        watcher.start()

        try "a = 2".write(to: file, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(400))

        #expect(fired >= 1)
        watcher.stop()
    }

    /// home-manager がファイル単位でリンクを張り替えるケース。
    @Test("ファイルのシンボリックリンクの張り替えを検知する")
    func detectsFileSymlinkSwap() async throws {
        let base = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let genA = base.appendingPathComponent("a.toml")
        let genB = base.appendingPathComponent("b.toml")
        try "a = 1".write(to: genA, atomically: true, encoding: .utf8)
        try "a = 2".write(to: genB, atomically: true, encoding: .utf8)

        let directory = base.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("config.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: genA)

        let watcher = ConfigWatcher(
            directory: directory.path, fileNames: ["config.toml"], debounce: 0.05)
        var fired = 0
        watcher.onChange = { fired += 1 }
        watcher.start()

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: genB)
        try await Task.sleep(for: .milliseconds(400))

        #expect(fired >= 1)
        watcher.stop()
    }

    /// ディレクトリごとリンクになっているケース。ファイルの fd も
    /// ディレクトリの fd も古い実体を指したままなので、親を見ていないと気づけない。
    @Test("ディレクトリのシンボリックリンクの張り替えを検知する")
    func detectsDirectorySymlinkSwap() async throws {
        let base = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let genA = base.appendingPathComponent("gen-a", isDirectory: true)
        let genB = base.appendingPathComponent("gen-b", isDirectory: true)
        for generation in [genA, genB] {
            try FileManager.default.createDirectory(
                at: generation, withIntermediateDirectories: true)
            try "a = 1".write(
                to: generation.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }

        let link = base.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: genA)

        let watcher = ConfigWatcher(
            directory: link.path, fileNames: ["config.toml"], debounce: 0.05)
        var fired = 0
        watcher.onChange = { fired += 1 }
        watcher.start()
        #expect(watcher.isWatchingParent)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: genB)
        try await Task.sleep(for: .milliseconds(400))

        #expect(fired >= 1)
        watcher.stop()
    }

    /// 設定ディレクトリが後から作られたら、そこから先は直接見る。
    @Test("ディレクトリが作られたら直接掴みに切り替える")
    func upgradesToDirectoryWatchWhenCreated() async throws {
        let base = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let directory = base.appendingPathComponent("compass", isDirectory: true)
        let watcher = ConfigWatcher(
            directory: directory.path, fileNames: ["config.toml"], debounce: 0.05)
        watcher.start()
        #expect(watcher.isWatchingDirectory == false)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(400))

        #expect(watcher.isWatchingDirectory)
        #expect(watcher.isWatchingParent == false)
        watcher.stop()
    }
}
