import Foundation
import Testing
@testable import GameCore

struct ProcessRunnerTests {
    private func shell(_ script: String, in dir: URL) -> LaunchPlan {
        LaunchPlan(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: dir, backend: nil, sandboxProfile: nil
        )
    }

    private func run(_ script: String) async throws -> (result: RunResult, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "GameCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let result = try await ProcessRunner.run(
            shell(script, in: try dir.makeDirectory()), log: dir.appending(path: "logs/launch.log"),
            wineserver: URL(fileURLWithPath: "/usr/bin/true")
        )
        return (result, dir)
    }

    @Test func logsHeaderStdoutAndStderr() async throws {
        let (result, dir) = try await run("echo out; echo err >&2; exit 3")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(result.status == 3)
        let log = try String(contentsOf: result.log, encoding: .utf8)
        #expect(log.hasPrefix("# "))
        #expect(log.contains("# command: /bin/sh -c"))
        #expect(log.hasSuffix("out\nerr\n"))
    }

    /// Wine passes stdout/stderr to the bottle's wineserver, which in an isolated bottle may run in
    /// another launch's sandbox. That sandbox can't take a file in this launch's log folder, but
    /// it can take a pipe.
    @Test func programsWriteToAPipeNotTheLogFile() async throws {
        let (result, dir) = try await run("[ -p /dev/fd/1 ] && [ -p /dev/fd/2 ] && echo pipes")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try String(contentsOf: result.log, encoding: .utf8).hasSuffix("pipes\n"))
    }

    @Test func keepsLoggingProgramsThatOutliveTheLaunch() async throws {
        let start = ContinuousClock.now
        let (result, dir) = try await run("(sleep 1; echo late) & echo early")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ContinuousClock.now - start < .seconds(1), "returns when the launched process exits")
        #expect(try String(contentsOf: result.log, encoding: .utf8).hasSuffix("early\n"))

        let deadline = ContinuousClock.now + .seconds(5)
        while try !String(contentsOf: result.log, encoding: .utf8).hasSuffix("late\n"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try String(contentsOf: result.log, encoding: .utf8).hasSuffix("early\nlate\n"))
    }
}
