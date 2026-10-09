import Foundation

public enum WindowsVersion: String, Codable, Sendable {
    case windows7 = "win7"
    case windows10 = "win10"
    case windows11 = "win11"
}

/// A Wine prefix plus the settings it runs with.
public struct Bottle: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case standard
        /// Runs inside the macOS sandbox, cut off from your files, other apps and (by default) the internet.
        case isolated
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var engineID: String
    public var windowsVersion: WindowsVersion
    /// Only used when `kind == .isolated`.
    public var isolation: IsolationPolicy
    public var createdAt: Date
    /// `RuntimeModules.fingerprint` of the runtime the prefix was last booted with (`wineboot`); nil
    /// for bottles that predate it or were reset to a snapshot, so the next launch updates them.
    public var runtimeModules: String?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind = .standard,
        engineID: String,
        windowsVersion: WindowsVersion = .windows10,
        isolation: IsolationPolicy = IsolationPolicy(),
        createdAt: Date = .now,
        runtimeModules: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.engineID = engineID
        self.windowsVersion = windowsVersion
        self.isolation = isolation
        self.createdAt = createdAt
        self.runtimeModules = runtimeModules
    }
}

/// A bottle's folders. Only `prefix` and `home` are writable from inside an isolated bottle;
/// `bottle.json` and the clean snapshot sit beside them so a sandboxed program can't edit
/// its own isolation settings or poison the snapshot.
public struct BottleLocation: Sendable, Equatable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public init(bottleID: UUID, paths: AppPaths) {
        directory = paths.bottles.appending(path: bottleID.uuidString, directoryHint: .isDirectory)
    }

    /// WINEPREFIX.
    public var prefix: URL { directory.appending(path: "prefix", directoryHint: .isDirectory) }
    /// HOME for isolated launches, so Unix-side libraries never touch your real home folder.
    public var home: URL { directory.appending(path: "home", directoryHint: .isDirectory) }
    public var metadata: URL { directory.appending(path: "bottle.json") }
    public var cleanSnapshot: URL { directory.appending(path: "snapshot-clean", directoryHint: .isDirectory) }
}
