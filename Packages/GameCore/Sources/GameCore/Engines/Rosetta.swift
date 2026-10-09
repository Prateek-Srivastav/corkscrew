import Foundation

/// Rosetta 2, which runs the x86_64 Wine runtime. Macs don't have it until something asks for it.
public enum Rosetta {
    public enum InstallError: Error, Equatable, CustomStringConvertible {
        case cancelled
        case failed(status: Int32, output: String)

        public var description: String {
            switch self {
            case .cancelled: "Rosetta wasn't installed: the password prompt was cancelled"
            case .failed(let status, let output): "installing Rosetta failed (exit \(status)): \(output)"
            }
        }
    }

    /// Whether x86_64 programs run: starts the x86_64 half of `/usr/bin/true`.
    public static var isInstalled: Bool {
        (try? run("/usr/bin/arch", ["-x86_64", "/usr/bin/true"]).status) == 0
    }

    /// Installs Rosetta with `softwareupdate`, which needs an administrator: macOS asks for the
    /// password. Blocks until it's done (a download of a few hundred MB).
    public static func install() throws {
        let command = "/usr/sbin/softwareupdate --install-rosetta --agree-to-license"
        let result = try run("/usr/bin/osascript", ["-e", "do shell script \"\(command)\" with administrator privileges"])
        guard result.status == 0 else {
            // osascript reports a cancelled password prompt as AppleScript error -128.
            if result.output.contains("-128") { throw InstallError.cancelled }
            throw InstallError.failed(status: result.status, output: result.output)
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
