import Foundation
import Testing
@testable import GameCore

struct BottleStoreTests {
    /// A runtime whose `wine` records its arguments and whose `wineserver` does nothing.
    private func recordingEngine(in root: URL) throws -> (Engine, URL) {
        let runtime = root.appending(path: "runtime")
        let record = root.appending(path: "wine-arguments.txt")
        for (tool, script) in [("wine", "echo \"$@\" >> '\(record.path)'"), ("wineserver", "exit 0")] {
            let file = runtime.appending(path: "bin/\(tool)")
            try file.write("#!/bin/sh\n\(script)\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return (Engine(id: "winecx-test", root: runtime, architecture: .x86_64), record)
    }

    /// A plain `wineboot --update` also starts everything registered to run at Windows startup
    /// (Steam with -silent), so the setup session never ended and the launch waited forever.
    @Test func updatingABottleDoesNotStartItsStartupPrograms() async throws {
        try await withTempDir { root in
            let paths = RuntimeStoreTests.paths(root)
            let (engine, record) = try recordingEngine(in: root)
            let store = BottleStore(paths: paths, hostEnvironment: ["HOME": root.path])
            let bottle = Bottle(name: "Games", kind: .standard, engineID: engine.id)
            try store.save(bottle)
            try store.location(of: bottle).prefix.makeDirectory()

            let updated = try await store.update(bottle, engine: engine)
            #expect(try String(contentsOf: record, encoding: .utf8) == "wineboot --update --restart\n")
            #expect(updated.runtimeModules == RuntimeModules.fingerprint(runtime: engine.root))
        }
    }
}
