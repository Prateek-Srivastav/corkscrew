import Foundation
import Testing
@testable import GameCore

struct BottleImportTests {
    private func bottle(in paths: AppPaths, kind: Bottle.Kind = .isolated) throws -> Bottle {
        let bottle = Bottle(name: "Sandbox", kind: kind, engineID: "winecx-test")
        try BottleStore(paths: paths).save(bottle)
        try BottleLocation(bottleID: bottle.id, paths: paths).prefix.appending(path: "drive_c/users/crossover/AppData").makeDirectory()
        try BottleLocation(bottleID: bottle.id, paths: paths).prefix.appending(path: "drive_c/users/Public").makeDirectory()
        return bottle
    }

    @Test func importsAProgramWithItsSplitFilesIntoDownloads() throws {
        try withTempDir { root in
            let paths = RuntimeStoreTests.paths(root)
            let store = BottleStore(paths: paths)
            let target = try bottle(in: paths)
            let downloads = root.appending(path: "Downloads")
            for name in ["setup_game.exe", "setup_game-1.bin", "Setup_Game-2.bin", "setup_game_editor.exe", "other.exe"] {
                try downloads.appending(path: name).write(name)
            }

            let imported = try store.importProgram(downloads.appending(path: "setup_game.exe"), into: target)
            let expected = BottleLocation(bottleID: target.id, paths: paths).prefix.appending(path: "drive_c/users/crossover/Downloads")
            #expect(imported == expected.appending(path: "setup_game.exe"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: expected.path).sorted()
                    == ["Setup_Game-2.bin", "setup_game-1.bin", "setup_game.exe"])
            // Importing again reuses the copies; a changed file is replaced.
            try downloads.appending(path: "setup_game-1.bin").write("a newer, longer part")
            #expect(try store.importProgram(downloads.appending(path: "setup_game.exe"), into: target) == imported)
            #expect(try String(contentsOf: expected.appending(path: "setup_game-1.bin"), encoding: .utf8) == "a newer, longer part")
        }
    }

    @Test func importsABottleFolderOnce() throws {
        try withTempDir { root in
            let elsewhere = RuntimeStoreTests.paths(root.appending(path: "dev-data"))
            let original = try bottle(in: elsewhere)
            let paths = RuntimeStoreTests.paths(root.appending(path: "app"))
            let store = BottleStore(paths: paths)

            let folder = BottleLocation(bottleID: original.id, paths: elsewhere).directory
            // bottle.json stores whole seconds, so compare what identifies the bottle.
            #expect(try store.importBottle(from: folder).id == original.id)
            #expect(try store.list().map(\.id) == [original.id])
            #expect(FileManager.default.fileExists(atPath: store.location(of: original).prefix.appending(path: "drive_c/users/crossover").path))
            #expect(throws: BottleStore.StoreError.alreadyExists("Sandbox")) { try store.importBottle(from: folder) }
        }
    }

    @Test func importsKnownComponentsAndKeepsExistingOnes() throws {
        try withTempDir { root in
            let source = root.appending(path: "build/components")
            for name in ["dxmt-0.80", "d3dmetal-3.0", "moltenvk-1.4.2"] { try source.appending(path: "\(name)/marker").write(name) }
            let components = RuntimeStoreTests.paths(root).components
            try components.appending(path: "d3dmetal-3.0/marker").write("already here")

            #expect(try ComponentCatalog.importComponents(from: source, into: components) == ["dxmt-0.80"])
            #expect(ComponentCatalog.staged(in: components) == ["d3dmetal-3.0", "dxmt-0.80"])
            #expect(try String(contentsOf: components.appending(path: "d3dmetal-3.0/marker"), encoding: .utf8) == "already here")
        }
    }

    @Test func findsTheEngineForABottlesRuntime() throws {
        try withTempDir { root in
            let paths = RuntimeStoreTests.paths(root)
            let store = RuntimeStore(paths: paths)
            #expect(try store.engine() == nil)
            for id in ["winecx-a-x86_64", "winecx-b-x86_64"] {
                try RuntimeStoreTests.makeRuntime(at: root.appending(path: "src/\(id)"), id: id)
                try store.install(directory: root.appending(path: "src/\(id)"))
            }
            try paths.components.appending(path: "dxmt-0.80/x86_64-windows").makeDirectory()

            #expect(try store.engine(id: "winecx-a-x86_64")?.id == "winecx-a-x86_64")
            #expect(try store.engine(id: "missing")?.id == "winecx-b-x86_64")
            let engine = try #require(try store.engine())
            #expect(engine.root == store.location(of: "winecx-b-x86_64"))
            #expect(engine.backendDLLPaths[.dxmt]?.map(\.lastPathComponent) == ["dxmt-0.80"])
        }
    }
}
