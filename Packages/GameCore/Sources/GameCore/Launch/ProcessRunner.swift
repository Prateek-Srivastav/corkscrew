import Foundation

public struct RunResult: Sendable, Equatable {
    /// The exit code, or the signal number when `crashed`.
    public let status: Int32
    public let log: URL
    /// A signal ended the program (11 is SIGSEGV) instead of an exit.
    public var crashed = false

    /// "exit 3" or "crashed, signal 11", for error messages.
    public var outcome: String { crashed ? "crashed, signal \(status)" : "exit \(status)" }
}

/// Runs a `LaunchPlan` and records everything it prints.
public enum ProcessRunner {
    /// Runs `plan` to completion, writing a header and all output to `log`. Programs it started
    /// that are still running when it returns keep logging there for as long as this app runs.
    ///
    /// Cancelling the calling task stops the whole Wine session for the bottle (`wineserver -k`),
    /// not just the first process, since games usually spawn more.
    public static func run(_ plan: LaunchPlan, log: URL, wineserver: URL) async throws -> RunResult {
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: header(for: plan))
        let output = try FileHandle(forWritingTo: log)
        try output.seekToEnd()
        // Programs write to a pipe, never to the log file itself. Wine turns stdout/stderr into
        // Windows handles by passing the descriptors to the bottle's wineserver, and in an isolated
        // bottle that server runs in the sandbox of whichever launch started the session. A file
        // only gets through if every sandbox on the way allows its path, and each launch allows
        // only its own log folder, so a second program's handles came out invalid and its output
        // was lost. A pipe has no path to check.
        let pipe = Pipe()
        let pump = LogPump(from: pipe.fileHandleForReading, to: output)

        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = plan.workingDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        let box = ProcessBox(process)

        let (status, reason): (Int32, Process.TerminationReason) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: ($0.terminationStatus, $0.terminationReason)) }
                do {
                    // A launch cancelled before this point never starts its program.
                    if try !box.start() {
                        process.terminationHandler = nil
                        continuation.resume(throwing: CancellationError())
                    }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
                // Only the programs may hold the writing end, so the pump sees the end of the
                // output once the last of them exits.
                try? pipe.fileHandleForWriting.close()
            }
        } onCancel: {
            // Runs right away when the task was cancelled before this call; `box` then keeps the
            // program from starting. Otherwise it stops the program and everything it started.
            box.cancel()
            stopSession(environment: plan.environment, wineserver: wineserver)
        }
        pump.copyPending()
        return RunResult(status: status, log: log, crashed: reason == .uncaughtSignal)
    }

    /// Kills every process of the bottle named by `WINEPREFIX` in `environment`.
    public static func stopSession(environment: [String: String], wineserver: URL) {
        let kill = Process()
        kill.executableURL = wineserver
        kill.arguments = ["-k"]
        kill.environment = environment.filter { ["WINEPREFIX", "HOME", "TMPDIR", "PATH"].contains($0.key) }
        kill.standardOutput = FileHandle.nullDevice
        kill.standardError = FileHandle.nullDevice
        try? kill.run()
        kill.waitUntilExit()
    }

    /// Waits until the bottle's wineserver has exited, so the prefix (registry included) is settled
    /// on disk. With a `timeout`, gives up after it and returns false if the bottle is still running.
    @discardableResult
    public static func waitForSession(environment: [String: String], wineserver: URL, timeout: Duration? = nil) -> Bool {
        let wait = Process()
        wait.executableURL = wineserver
        wait.arguments = ["-w"]
        wait.environment = environment.filter { ["WINEPREFIX", "HOME", "TMPDIR", "PATH"].contains($0.key) }
        wait.standardOutput = FileHandle.nullDevice
        wait.standardError = FileHandle.nullDevice
        guard (try? wait.run()) != nil else { return false }
        if let timeout {
            let deadline = ContinuousClock.now + timeout
            while wait.isRunning, ContinuousClock.now < deadline { usleep(100_000) }
            if wait.isRunning { wait.terminate(); return false }
        }
        wait.waitUntilExit()
        return true
    }

    private static func header(for plan: LaunchPlan) -> Data {
        var lines = [
            "# \(ISO8601DateFormatter().string(from: .now))",
            "# backend: \(plan.backend?.rawValue ?? "-")",
            "# cwd: \(plan.workingDirectory.path)",
            "# command: \(([plan.executable.path] + plan.arguments.map { $0.contains("\n") ? "<sandbox profile>" : $0 }).joined(separator: " "))",
        ]
        let shown = ["WINEPREFIX", "WINEDLLPATH", "WINEDLLOVERRIDES", "CX_ACTIVE_GRAPHICS_BACKEND", "WINEDEBUG", "HOME"]
        lines += shown.compactMap { key in plan.environment[key].map { "# \(key)=\($0)" } }
        if let profile = plan.sandboxProfile {
            lines += ["# sandbox profile:"] + profile.split(separator: "\n").map { "#   \($0)" }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}

/// Starting and cancelling a launch, which can race: a cancellation may arrive before, during or
/// after `run()`. Unchecked Sendable: `process` is only touched under `lock`.
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var cancelled = false

    init(_ process: Process) { self.process = process }

    /// Starts the process, unless the launch was cancelled first (then returns false).
    func start() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        try process.run()
        return true
    }

    /// Cancels the launch: a process that hasn't started won't, one that has is terminated.
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process.isRunning { process.terminate() }
    }
}

/// Copies a pipe into a log file on its own queue until every writer has closed the pipe. That can
/// be long after the launched process exits: programs it started inherit its output.
/// Unchecked Sendable: all state is only touched on `queue`.
private final class LogPump: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ProcessRunner.LogPump")
    private let reader: FileHandle
    private let output: FileHandle
    private let source: DispatchSourceRead
    private var finished = false

    init(from reader: FileHandle, to output: FileHandle) {
        self.reader = reader
        self.output = output
        let fd = reader.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // The handlers keep the pump alive until the pipe closes; the source drops them once cancelled.
        source.setEventHandler { self.copyAvailable() }
        source.setCancelHandler {
            try? self.reader.close()
            try? self.output.close()
        }
        source.resume()
    }

    /// Copies everything already written, so the log is complete for a process that has exited.
    func copyPending() {
        queue.sync { copyAvailable() }
    }

    private func copyAvailable() {
        guard !finished else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(reader.fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                try? output.write(contentsOf: buffer[..<count])
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { return }
            // End of file (every writer has exited) or a read error.
            finished = true
            source.cancel()
            return
        }
    }
}
