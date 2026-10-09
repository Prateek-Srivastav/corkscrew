import Foundation
import Testing
@testable import GameCore

struct EnginePackTests {
    /// A pack laid out as scripts/package-engine.sh makes it, compressed like it.
    static func makePack(in root: URL) throws -> URL {
        let top = root.appending(path: "src/corkscrew-engine-test")
        try RuntimeStoreTests.makeRuntime(at: top.appending(path: "runtime/winecx-test"))
        try top.appending(path: "components/dxmt-0.80/x86_64-windows/d3d11.dll").write("MZ")
        try top.appending(path: "components/dxvk-macos-1.10/x86_64-windows/d3d9.dll").write("MZ")
        try top.appending(path: "LICENSES/wine/COPYING.LIB").write("LGPL")
        let archive = root.appending(path: "corkscrew-engine-test.tar.xz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cJf", archive.path, "-C", root.appending(path: "src").path, "corkscrew-engine-test"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
        return archive
    }

    @Test func installsTheRuntimeAndComponents() throws {
        try withTempDir { root in
            let archive = try Self.makePack(in: root)
            let paths = RuntimeStoreTests.paths(root)
            let sha = try RuntimeStore.sha256(of: archive)

            #expect(throws: RuntimeStore.StoreError.self) {
                try Self.pack("1-1", sha256: String(repeating: "0", count: 64)).install(archive: archive, paths: paths)
            }
            #expect(RuntimeStore(paths: paths).list().isEmpty)

            #expect(try Self.pack("1-1", sha256: sha).install(archive: archive, paths: paths).id == "winecx-test-x86_64")
            #expect(RuntimeStore(paths: paths).list().map(\.id) == ["winecx-test-x86_64"])
            #expect(RuntimeStore(paths: paths).packVersion(of: "winecx-test-x86_64") == "1-1")
            #expect(ComponentCatalog.staged(in: paths.components) == ["dxmt-0.80", "dxvk-macos-1.10"])
            // No staging folder is left behind.
            #expect(try FileManager.default.contentsOfDirectory(atPath: paths.runtimes.path) == ["winecx-test-x86_64"])

            // Installing it again (say, after a failed bottle setup) keeps what's there.
            #expect(try Self.pack("1-1", sha256: sha).install(archive: archive, paths: paths).id == "winecx-test-x86_64")
        }
    }

    @Test func refusesAPackWithoutARuntime() throws {
        try withTempDir { root in
            try root.appending(path: "src/corkscrew-engine-test/components/dxmt-0.80/x86_64-windows/d3d11.dll").write("MZ")
            let archive = root.appending(path: "pack.tar.gz")
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-czf", archive.path, "-C", root.appending(path: "src").path, "corkscrew-engine-test"]
            try tar.run()
            tar.waitUntilExit()
            #expect(throws: EnginePack.PackError.missingRuntime) {
                try Self.pack("1-1", sha256: try RuntimeStore.sha256(of: archive)).install(archive: archive, paths: RuntimeStoreTests.paths(root))
            }
        }
    }

    static func pack(_ version: String, sha256: String) -> EnginePack {
        EnginePack(version: version, url: URL(string: "https://example.invalid/pack.tar.xz")!, sha256: sha256, size: 0)
    }

    /// A pack revision rebuilds the same Wine version, so its runtime has the installed one's id. It
    /// must replace it: 26.3.0-1 crashed on macOS 26, and 26.3.0-2 has to reach those Macs.
    @Test func aNewerPackReplacesTheRuntimeAndComponents() throws {
        try withTempDir { root in
            let archive = try Self.makePack(in: root)
            let sha = try RuntimeStore.sha256(of: archive)
            let paths = RuntimeStoreTests.paths(root)
            let store = RuntimeStore(paths: paths)
            try Self.pack("26.3.0-1", sha256: sha).install(archive: archive, paths: paths)
            let leftover = store.location(of: "winecx-test-x86_64").appending(path: "bin/broken")
            try leftover.write("from the old build")
            try paths.components.appending(path: "dxmt-0.80/x86_64-windows/d3d11.dll").write("old")

            #expect(Self.pack("26.3.0-1", sha256: sha).upgradesInstalledRuntime(in: paths) == false)
            #expect(Self.pack("26.3.0-10", sha256: sha).upgradesInstalledRuntime(in: paths))
            #expect(Self.pack("26.3.0-0", sha256: sha).upgradesInstalledRuntime(in: paths) == false)

            try Self.pack("26.3.0-10", sha256: sha).install(archive: archive, paths: paths)
            #expect(store.packVersion(of: "winecx-test-x86_64") == "26.3.0-10")
            #expect(!FileManager.default.fileExists(atPath: leftover.path))
            #expect(try String(contentsOf: paths.components.appending(path: "dxmt-0.80/x86_64-windows/d3d11.dll"), encoding: .utf8) == "MZ")
            #expect(try FileManager.default.contentsOfDirectory(atPath: paths.runtimes.path) == ["winecx-test-x86_64"])
            #expect(Self.pack("26.3.0-10", sha256: sha).upgradesInstalledRuntime(in: paths) == false)
        }
    }

    /// Runtimes from engine pack 26.3.0-1 have no record of their pack; they count as older.
    @Test func aRuntimeWithoutAPackRecordIsUpgraded() throws {
        try withTempDir { root in
            let archive = try Self.makePack(in: root)
            let sha = try RuntimeStore.sha256(of: archive)
            let paths = RuntimeStoreTests.paths(root)
            try RuntimeStoreTests.makeRuntime(at: paths.runtimes.appending(path: "winecx-test-x86_64"))
            #expect(Self.pack("26.3.0-2", sha256: sha).upgradesInstalledRuntime(in: paths))
            try Self.pack("26.3.0-2", sha256: sha).install(archive: archive, paths: paths)
            #expect(RuntimeStore(paths: paths).packVersion(of: "winecx-test-x86_64") == "26.3.0-2")
        }
    }

    /// A runtime built on this Mac (or added by hand) is the developer's; a pack never replaces it.
    @Test func keepsALocallyBuiltRuntime() throws {
        try withTempDir { root in
            let archive = try Self.makePack(in: root)
            let sha = try RuntimeStore.sha256(of: archive)
            let paths = RuntimeStoreTests.paths(root)
            let build = root.appending(path: "build/winecx-test")
            try RuntimeStoreTests.makeRuntime(at: build)
            try RuntimeStore(paths: paths).install(directory: build)

            #expect(Self.pack("26.3.0-2", sha256: sha).upgradesInstalledRuntime(in: paths) == false)
            try Self.pack("26.3.0-2", sha256: sha).install(archive: archive, paths: paths)
            #expect(RuntimeStore(paths: paths).packVersion(of: "winecx-test-x86_64") == RuntimeStore.localBuild)
        }
    }

    @Test func doesNotReplaceTheRuntimeUnderARunningBottle() throws {
        try withTempDir { root in
            let archive = try Self.makePack(in: root)
            let sha = try RuntimeStore.sha256(of: archive)
            let paths = RuntimeStoreTests.paths(root)
            try Self.pack("26.3.0-1", sha256: sha).install(archive: archive, paths: paths)
            let bottles = BottleStore(paths: paths)
            let bottle = Bottle(name: "Games", kind: .standard, engineID: "winecx-test-x86_64")
            try bottles.save(bottle)
            let prefix = try bottles.location(of: bottle).prefix.makeDirectory()
            try WineServer.directory(forPrefix: prefix, base: paths.wineServerDirectory).appending(path: "socket").write("")

            #expect(throws: EnginePack.PackError.bottlesRunning(["Games"])) {
                try Self.pack("26.3.0-2", sha256: sha).install(archive: archive, paths: paths)
            }
            #expect(RuntimeStore(paths: paths).packVersion(of: "winecx-test-x86_64") == "26.3.0-1")
            // No staging folder is left behind.
            #expect(try FileManager.default.contentsOfDirectory(atPath: paths.runtimes.path) == ["winecx-test-x86_64"])
        }
    }

    @Test func comparesReleasesByNumber() {
        #expect(EnginePack.isOlder("26.3.0-9", than: "26.3.0-10"))
        #expect(EnginePack.isOlder("26.3.0-2", than: "27.0.0-1"))
        #expect(EnginePack.isOlder("", than: "26.3.0-1"))
        #expect(!EnginePack.isOlder("26.3.0-2", than: "26.3.0-2"))
        #expect(!EnginePack.isOlder("26.3.0-2", than: "26.3.0-1"))
    }

    @Test func downloadsAndReplacesTheDestination() async throws {
        try await withTempDir { root in
            let source = root.appending(path: "pack.bin")
            try source.write(Data(repeating: 7, count: 1 << 20))
            let destination = root.appending(path: "downloads/pack.bin")
            try destination.write("an older, partial download")

            try await Downloader.download(source, to: destination) { _ in }
            #expect(try Data(contentsOf: destination) == Data(contentsOf: source))

            await #expect(throws: (any Error).self) {
                try await Downloader.download(root.appending(path: "missing.bin"), to: destination) { _ in }
            }
        }
    }
}
