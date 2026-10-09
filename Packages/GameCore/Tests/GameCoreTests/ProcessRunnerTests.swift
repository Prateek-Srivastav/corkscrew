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

    /// A launch cancelled before its program starts must not start it: the cancellation handler
    /// runs first, when there's nothing to stop yet.
    @Test func aCancelledLaunchNeverStartsItsProgram() async throws {
        let dir = try FileManager.default.temporaryDirectory
            .appending(path: "GameCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory).makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appending(path: "started")
        let plan = shell("touch '\(marker.path)'", in: dir)
        let launch = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner.run(plan, log: dir.appending(path: "launch.log"), wineserver: URL(fileURLWithPath: "/usr/bin/true"))
        }
        await #expect(throws: CancellationError.self) { try await launch.value }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
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

    /// A crash (Wine calling a function the Mac doesn't have) must not read as an exit code.
    @Test func reportsACrashAsASignal() async throws {
        let (result, dir) = try await run("kill -SEGV $$")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(result.crashed)
        #expect(result.outcome == "crashed, signal 11")
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

struct BottleProcessesTests {
    /// KERN_PROCARGS2 bytes: argc, executable path, padding, arguments, environment, apple strings.
    private func procargs(_ arguments: [String], environment: [String]) -> ArraySlice<UInt8> {
        var bytes = withUnsafeBytes(of: Int32(arguments.count).littleEndian) { Array($0) }
        bytes += Array("/path/to/wine".utf8) + [0, 0, 0, 0]
        for string in arguments + environment { bytes += Array(string.utf8) + [0] }
        bytes += [0] + Array("executable_path=/path/to/wine".utf8) + [0]
        return bytes[...]
    }

    @Test func emptyArgumentsDontShiftTheEnvironment() throws {
        // An argument that looks like the bottle's WINEPREFIX must not count as the environment.
        let parsed = try #require(BottleProcesses.parseProcessArguments(
            procargs(["C:\\game.exe", "", "WINEPREFIX=/bottle"], environment: ["WINEPREFIX=/other", "HOME=/h"])))
        #expect(parsed.arguments == ["C:\\game.exe", "", "WINEPREFIX=/bottle"])
        #expect(parsed.environment == ["WINEPREFIX": "/other", "HOME": "/h"])
        // Cut off inside "beta": header (4), path and padding (17), "alpha\0" (6), "be".
        #expect(BottleProcesses.parseProcessArguments(procargs(["alpha", "beta"], environment: []).prefix(29)) == nil)
    }

    /// Wine writes the Windows path over its arguments and zeroes what's left of their space. Without
    /// skipping those NULs the environment came out empty: no Steam game was ever seen running, so
    /// nothing was closed after it quit.
    @Test func findsTheEnvironmentAfterWineRewritesItsArguments() throws {
        var bytes = withUnsafeBytes(of: Int32(2).littleEndian) { Array($0) }
        bytes += Array("/var/folders/T/winetemp-1".utf8) + [0, 0, 0, 0]
        bytes += Array("C:\\windows\\system32\\notepad.exe".utf8) + [0] + [0] + [UInt8](repeating: 0, count: 108)
        bytes += Array("WINEPREFIX=/bottle".utf8) + [0] + Array("HOME=/h".utf8) + [0, 0]
        bytes += Array("executable_path=/path/to/wine".utf8) + [0]
        let parsed = try #require(BottleProcesses.parseProcessArguments(bytes[...]))
        #expect(parsed.arguments == ["C:\\windows\\system32\\notepad.exe", ""])
        #expect(parsed.environment == ["WINEPREFIX": "/bottle", "HOME": "/h"])
    }

    /// macOS hides the environment of its own system binaries, so the stand-in for Wine is a re-signed copy.
    @Test func readsARealProcess() throws {
        try withTempDir { dir in
            let sleep = dir.appending(path: "sleep")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: sleep)
            let sign = try Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", sleep.path])
            sign.waitUntilExit()
            let process = Process()
            process.executableURL = sleep
            process.arguments = ["5"]
            process.environment = ["WINEPREFIX": "/corkscrew-test-prefix"]
            try process.run()
            defer { process.terminate() }
            let parsed = try #require(BottleProcesses.processArguments(of: process.processIdentifier))
            #expect(parsed.arguments == [sleep.path, "5"])
            #expect(parsed.environment["WINEPREFIX"] == "/corkscrew-test-prefix")
        }
    }
}
