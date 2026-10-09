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
                try EnginePack.install(archive: archive, sha256: String(repeating: "0", count: 64), paths: paths)
            }
            #expect(RuntimeStore(paths: paths).list().isEmpty)

            #expect(try EnginePack.install(archive: archive, sha256: sha, paths: paths).id == "winecx-test-x86_64")
            #expect(RuntimeStore(paths: paths).list().map(\.id) == ["winecx-test-x86_64"])
            #expect(ComponentCatalog.staged(in: paths.components) == ["dxmt-0.80", "dxvk-macos-1.10"])
            // No staging folder is left behind.
            #expect(try FileManager.default.contentsOfDirectory(atPath: paths.runtimes.path) == ["winecx-test-x86_64"])

            // Installing it again (say, after a failed bottle setup) keeps what's there.
            #expect(try EnginePack.install(archive: archive, sha256: sha, paths: paths).id == "winecx-test-x86_64")
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
                try EnginePack.install(archive: archive, sha256: try RuntimeStore.sha256(of: archive), paths: RuntimeStoreTests.paths(root))
            }
        }
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
