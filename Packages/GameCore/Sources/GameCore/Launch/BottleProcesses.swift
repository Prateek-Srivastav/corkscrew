import Darwin
import Foundation

/// A bottle's running Wine processes, found by the `WINEPREFIX` in their environment. A Wine
/// process's first argument is its Windows path (`C:\Program Files (x86)\Steam\steam.exe`).
public enum BottleProcesses {
    public struct Entry: Equatable, Sendable {
        public var pid: pid_t
        public var arguments: [String]

        /// The Windows program, lowercased.
        var program: String { arguments.first?.lowercased() ?? "" }
    }

    /// Our own processes whose environment has WINEPREFIX=prefix.
    public static func list(prefix: URL) -> [Entry] {
        let prefix = prefix.standardizedFileURL.path
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var all = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.size))
        let me = getuid()
        return all.prefix(Int(max(filled, 0))).compactMap { pid in
            guard pid > 0 else { return nil }
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_uid == me,
                  let process = processArguments(of: pid),
                  process.environment["WINEPREFIX"].map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) == prefix
            else { return nil }
            return Entry(pid: pid, arguments: process.arguments)
        }
    }

    /// Whether Steam's client runs in the bottle.
    public static func isSteamRunning(prefix: URL) -> Bool {
        list(prefix: prefix).contains { isSteamClient($0.program) }
    }

    static func isSteamClient(_ program: String) -> Bool { program.hasSuffix("\\steam.exe") }

    /// Programs started from a Steam game's folder (`steamapps\common\<installDir>\…`), on any drive.
    static func isFromSteamGame(_ program: String, installDir: String) -> Bool {
        program.contains("\\steamapps\\common\\\(installDir.lowercased())\\")
    }

    /// Another process's arguments and environment (same user only), via KERN_PROCARGS2.
    static func processArguments(of pid: pid_t) -> (arguments: [String], environment: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcessArguments(buffer[..<size])
    }

    /// KERN_PROCARGS2 layout: argc, the executable path, NUL padding, then exactly argc NUL-terminated
    /// arguments (empty ones included), then environment strings up to an empty one. Counting the
    /// arguments, rather than splitting on NULs, keeps an empty argument from shifting the
    /// environment, and a program's arguments from passing as its environment.
    static func parseProcessArguments(_ bytes: ArraySlice<UInt8>) -> (arguments: [String], environment: [String: String])? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc >= 0 else { return nil }
        var index = bytes.startIndex + MemoryLayout<Int32>.size
        func nextString() -> String? {
            guard index < bytes.endIndex, let end = bytes[index...].firstIndex(of: 0) else { return nil }
            defer { index = end + 1 }
            return String(decoding: bytes[index..<end], as: UTF8.self)
        }
        guard nextString() != nil else { return nil }  // the executable path
        while index < bytes.endIndex, bytes[index] == 0 { index += 1 }  // padding
        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = nextString() else { return nil }
            arguments.append(argument)
        }
        var environment: [String: String] = [:]
        while let text = nextString(), !text.isEmpty {
            if let equals = text.firstIndex(of: "=") {
                environment[String(text[..<equals])] = String(text[text.index(after: equals)...])
            }
        }
        return (arguments, environment)
    }
}
