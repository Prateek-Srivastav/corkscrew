import Foundation
import Testing
@testable import GameCore

struct RuntimeStoreTests {
    /// A minimal runtime folder: manifest, an executable bin/wine and some Windows modules.
    static func makeRuntime(at folder: URL, id: String = "winecx-test-x86_64", modules: [String] = ["ntdll.dll", "kernel32.dll"]) throws {
        try folder.appending(path: "manifest.json").write("""
        {"id": "\(id)", "architecture": "x86_64", "source": "https://example.invalid/wine.tar.gz", "sourceSHA256": "00"}
        """)
        let wine = folder.appending(path: "bin/wine")
        try wine.write("#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        for module in modules { try folder.appending(path: "lib/wine/x86_64-windows/\(module)").write("MZ") }
    }

    static func paths(_ root: URL) -> AppPaths {
        AppPaths(supportRoot: root.appending(path: "support"), logsRoot: root.appending(path: "logs"),
                 cachesRoot: root.appending(path: "caches"), userHome: root, wineServerDirectory: root.appending(path: "wine-uid"))
    }

    @Test func installsAVerifiedArchiveAndRefusesABadOne() throws {
        try withTempDir { root in
            try Self.makeRuntime(at: root.appending(path: "src/winecx-test"))
            let archive = root.appending(path: "winecx-test.tar.gz")
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-czf", archive.path, "-C", root.appending(path: "src").path, "winecx-test"]
            try tar.run()
            tar.waitUntilExit()
            let store = RuntimeStore(paths: Self.paths(root))

            #expect(throws: RuntimeStore.StoreError.self) { try store.install(archive: archive, sha256: String(repeating: "0", count: 64)) }
            #expect(store.list().isEmpty)

            let sha = try RuntimeStore.sha256(of: archive)
            let manifest = try store.install(archive: archive, sha256: sha.uppercased())
            #expect(manifest.id == "winecx-test-x86_64")
            #expect(store.list().map(\.id) == ["winecx-test-x86_64"])
            #expect(FileManager.default.isExecutableFile(atPath: store.location(of: manifest.id).appending(path: "bin/wine").path))
            #expect(throws: RuntimeStore.StoreError.alreadyInstalled("winecx-test-x86_64")) {
                try store.install(archive: archive, sha256: sha)
            }
            // No staging folders are left behind.
            #expect(try FileManager.default.contentsOfDirectory(atPath: Self.paths(root).runtimes.path) == ["winecx-test-x86_64"])
        }
    }

    @Test func installsALocalBuildAndRejectsOtherFolders() throws {
        try withTempDir { root in
            let build = root.appending(path: "build/runtime/winecx-test")
            try Self.makeRuntime(at: build)
            let store = RuntimeStore(paths: Self.paths(root))
            #expect(try store.install(directory: build).id == "winecx-test-x86_64")
            #expect(FileManager.default.fileExists(atPath: build.path))  // the build stays where it was

            let notRuntime = try root.appending(path: "empty").makeDirectory()
            #expect(throws: RuntimeStore.StoreError.notARuntime(notRuntime.path)) { try store.install(directory: notRuntime) }
        }
    }

    @Test func moduleFingerprintChangesWithModuleNamesOnly() throws {
        try withTempDir { root in
            try Self.makeRuntime(at: root)
            let before = RuntimeModules.fingerprint(runtime: root)
            try root.appending(path: "lib/wine/x86_64-windows/ntdll.dll").write("MZ changed")
            #expect(RuntimeModules.fingerprint(runtime: root) == before)
            try root.appending(path: "lib/wine/x86_64-windows/winemetal.dll").write("MZ")
            #expect(RuntimeModules.fingerprint(runtime: root) != before)
        }
    }
}

struct BottleMaintenanceTests {
    @Test func launchesSkipUpToDateBottlesAndDeferForRunningOnes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GameCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appending(path: "runtime")
        try RuntimeStoreTests.makeRuntime(at: runtime)
        let engine = Engine(id: "winecx-test-x86_64", root: runtime, architecture: .x86_64)
        let paths = RuntimeStoreTests.paths(root)
        let store = BottleStore(paths: paths, hostEnvironment: [:])
        var bottle = Bottle(name: "games", engineID: engine.id, runtimeModules: RuntimeModules.fingerprint(runtime: runtime))
        try store.location(of: bottle).prefix.makeDirectory()

        #expect(try await store.prepareForLaunch(bottle, engine: engine) == .upToDate)

        // The runtime gains a module while something runs in the bottle: don't wait on it.
        try runtime.appending(path: "lib/wine/x86_64-windows/winemetal.dll").write("MZ")
        let server = try WineServer.directory(forPrefix: store.location(of: bottle).prefix, base: paths.wineServerDirectory)
        try server.appending(path: "socket").write("")
        #expect(try await store.prepareForLaunch(bottle, engine: engine) == .updateDeferred)

        bottle.runtimeModules = RuntimeModules.fingerprint(runtime: runtime)
        #expect(try await store.prepareForLaunch(bottle, engine: engine) == .upToDate)
    }

    @Test func bottlesSavedBeforeFingerprintsStillLoad() throws {
        let saved = try JSONEncoder.bottles.encode(Bottle(name: "old", engineID: "winecx", runtimeModules: "abc"))
        var json = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        json["runtimeModules"] = nil
        let bottle = try JSONDecoder.bottles.decode(Bottle.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(bottle.name == "old")
        #expect(bottle.runtimeModules == nil)
    }
}

struct GPTKImporterTests {
    @Test(arguments: [
        ("Evaluation environment for Windows games 3.0.dmg", "3.0"),
        ("Evaluation environment for Windows games 4.0 beta 2.dmg", "4.0b2"),
        ("Evaluation environment for Windows games 2.1.1.dmg", "2.1.1"),
    ])
    func readsTheVersionFromTheImageName(name: String, version: String) {
        #expect(GPTKImporter.version(fromImageName: name) == version)
    }

    @Test func importsANestedToolkitImage() throws {
        try withTempDir { root in
            // Shaped like Apple's download: an outer image holding the evaluation environment image.
            let env = root.appending(path: "env")
            let lib = env.appending(path: "redist/lib")
            try lib.appending(path: "external/libd3dshared.dylib").write("dylib")
            for dll in ["d3d12.dll", "dxgi.dll", "nvngx-on-metalfx.dll"] { try lib.appending(path: "wine/x86_64-windows/\(dll)").write("MZ") }
            try lib.appending(path: "wine/x86_64-unix").makeDirectory()
            for so in ["d3d12.so", "nvngx-on-metalfx.so"] {
                try FileManager.default.createSymbolicLink(atPath: lib.appending(path: "wine/x86_64-unix/\(so)").path,
                                                           withDestinationPath: "../../external/libd3dshared.dylib")
            }
            try env.appending(path: "License.rtf").write("license")
            let outerFolder = try root.appending(path: "outer").makeDirectory()
            try Self.makeImage(from: env, at: outerFolder.appending(path: "Evaluation environment for Windows games 9.1 beta 3.dmg"))
            let dmg = root.appending(path: "Game_Porting_Toolkit_9.1_beta_3.dmg")
            try Self.makeImage(from: outerFolder, at: dmg)

            let components = root.appending(path: "components")
            let staged = try GPTKImporter.importToolkit(dmg: dmg, into: components)
            let fm = FileManager.default
            #expect(staged.lastPathComponent == "d3dmetal-9.1b3")
            #expect(fm.fileExists(atPath: staged.appending(path: "wine/x86_64-windows/nvngx.dll").path))
            #expect(!fm.fileExists(atPath: staged.appending(path: "wine/x86_64-windows/nvngx-on-metalfx.dll").path))
            #expect(try fm.destinationOfSymbolicLink(atPath: staged.appending(path: "wine/x86_64-unix/libd3dshared.dylib").path)
                    == "../../external/libd3dshared.dylib")
            #expect(try String(contentsOf: staged.appending(path: "wine/x86_64-unix/nvngx.so"), encoding: .utf8) == "dylib")
            #expect(fm.fileExists(atPath: staged.appending(path: "Apple-License.rtf").path))
            #expect(try fm.contentsOfDirectory(atPath: components.path) == ["d3dmetal-9.1b3"])  // no staging left
            // Both images were detached.
            #expect(!Self.mountedImages().contains { $0.contains(root.lastPathComponent) || $0.contains("9.1 beta 3") })

            #expect(throws: GPTKImporter.ImportError.alreadyImported("d3dmetal-9.1b3")) {
                try GPTKImporter.importToolkit(dmg: dmg, into: components)
            }
        }
    }

    static func makeImage(from folder: URL, at image: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["create", "-quiet", "-fs", "HFS+", "-format", "UDRO", "-srcfolder", folder.path, image.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    static func mountedImages() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("image-path") }
    }
}
