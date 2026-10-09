import CoreGraphics
import Foundation

/// Which desktop Windows programs see on a Retina display.
///
/// macOS lays the desktop out in points: a 14" MacBook Pro "looks like" 1512×982 but has 3024×1964
/// pixels. Wine normally reports the points, so games render at 1512×982 and macOS scales the
/// picture up. With Retina mode on, Wine reports the default display mode at twice the size, in
/// pixels, so borderless and windowed games can render at full resolution: much sharper, and up
/// to four times the GPU work.
///
/// Wine reads `HKCU\Software\Wine\Mac Driver\RetinaMode` for the whole bottle (it deliberately
/// ignores per-program keys for this one), and the first process of a bottle session fixes the
/// monitor sizes every later program in that session sees. So the launcher sets the game's profile
/// value while the bottle is idle, then lets that short Wine session end before the game starts a
/// new one. While something runs in the bottle (Steam, say) the setting can't change; a game
/// started from Steam gets the setting Steam was launched with.
public enum RetinaMode {
    static let key = #"Software\Wine\Mac Driver"#
    static let name = "RetinaMode"

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case setFailed(status: Int32, log: String)
        /// The bottle is running with the other setting; changing it needs a fresh Wine session.
        case bottleRunning(isEnabled: Bool)
        public var description: String {
            switch self {
            case .setFailed(let status, let log): "couldn't set Retina mode (wine reg exited \(status)); see \(log)"
            case .bottleRunning(let isEnabled):
                "this bottle is running with Retina mode \(isEnabled ? "on" : "off"); quit everything in it "
                    + "(Steam too) to switch, or launch with the same setting"
            }
        }
    }

    /// The bottle's saved setting; a missing value means off.
    public static func isEnabled(prefix: URL) -> Bool {
        WineRegistry.isTrue(WineRegistry.value(name, inKey: key, file: prefix.appending(path: "user.reg")))
    }

    /// The `wine` arguments that store the setting.
    static func command(enabled: Bool) -> [String] {
        ["reg", "add", "HKCU\\" + key, "/v", name, "/t", "REG_SZ", "/d", enabled ? "y" : "n", "/f"]
    }

    /// Makes the bottle's setting match `enabled` before a launch. On an idle bottle it writes the
    /// value if needed and waits for that Wine session to end. A running session has already fixed
    /// its monitor sizes, so a different value waits briefly for it to wind down (a game that just
    /// quit), then throws.
    public static func apply(_ enabled: Bool, in context: WineContext, log: URL) async throws {
        let prefix = context.location.prefix
        if WineServer.isRunning(prefix: prefix, base: context.paths.wineServerDirectory) {
            // The saved user.reg can lag a running wineserver, so ask Wine.
            let current = try await run(queryCommand, in: context, log: log, allowFailure: true)
            if WineRegistry.isTrue(queriedValue(in: current)) == enabled { return }
        }
        // Let any session finish: wineserver -w returns once the server has saved the registry, which
        // is after it removes its socket. On an idle bottle it returns at once.
        guard ProcessRunner.waitForSession(environment: try sessionEnvironment(context),
                                           wineserver: context.engine.wineserver, timeout: .seconds(10))
        else { throw Error.bottleRunning(isEnabled: !enabled) }
        guard isEnabled(prefix: prefix) != enabled else { return }
        _ = try await run(command(enabled: enabled), in: context, log: log, allowFailure: false)
        ProcessRunner.waitForSession(environment: try sessionEnvironment(context), wineserver: context.engine.wineserver)
    }

    private static func sessionEnvironment(_ context: WineContext) throws -> [String: String] {
        try LaunchPlanner.plan(wineArguments: [], in: context).environment
    }

    static let queryCommand = ["reg", "query", "HKCU\\" + key, "/v", name]

    /// The data column of `reg query` output (`    RetinaMode    REG_SZ    y`); nil when missing.
    static func queriedValue(in output: String) -> String? {
        // reg.exe ends lines with \r\n, which Swift counts as one Character, so split on any newline.
        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(whereSeparator: \.isWhitespace)
            if columns.count >= 3, columns[0].lowercased() == name.lowercased(), columns[1].hasPrefix("REG_") {
                return columns[2...].joined(separator: " ")
            }
        }
        return nil
    }

    /// Runs a `wine reg` command and returns what it printed.
    private static func run(_ arguments: [String], in context: WineContext, log: URL, allowFailure: Bool) async throws -> String {
        let plan = try LaunchPlanner.plan(wineArguments: arguments, in: context)
        let result = try await ProcessRunner.run(plan, log: log, wineserver: context.engine.wineserver)
        guard allowFailure || result.status == 0 else { throw Error.setFailed(status: result.status, log: log.path) }
        return (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }

    /// The desktop size Windows programs see on the main display, assuming it's in the mode it had
    /// when you logged in (Wine only doubles that one).
    public static func desktopSize(enabled: Bool) -> (width: Int, height: Int)? {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return nil }
        let scale = enabled ? 2 : 1
        return (mode.width * scale, mode.height * scale)
    }
}
