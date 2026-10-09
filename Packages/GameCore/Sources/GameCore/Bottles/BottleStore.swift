import Foundation

/// Creates, lists and maintains bottles under `AppPaths.bottles`.
public struct BottleStore: Sendable {
    public enum StoreError: Error, Equatable, CustomStringConvertible {
        case notIsolated
        case noCleanSnapshot
        case setupFailed(outcome: String, log: String)
        case alreadyExists(String)

        public var description: String {
            switch self {
            case .notIsolated: "only isolated bottles have a clean snapshot"
            case .noCleanSnapshot: "this bottle has no clean snapshot to reset to"
            case .setupFailed(let outcome, let log): "Wine setup failed (\(outcome)); see \(log)"
            case .alreadyExists(let name): "the bottle \"\(name)\" is already here"
            }
        }
    }

    public let paths: AppPaths
    /// The app's own environment; `LaunchPlanner` passes on only locale and user basics.
    public let hostEnvironment: [String: String]

    public init(paths: AppPaths, hostEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.hostEnvironment = hostEnvironment
    }

    public func location(of bottle: Bottle) -> BottleLocation { BottleLocation(bottleID: bottle.id, paths: paths) }

    public func list() throws -> [Bottle] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: paths.bottles, includingPropertiesForKeys: nil)) ?? []
        return try folders.compactMap { folder in
            let metadata = BottleLocation(directory: folder).metadata
            guard FileManager.default.fileExists(atPath: metadata.path) else { return nil }
            return try JSONDecoder.bottles.decode(Bottle.self, from: Data(contentsOf: metadata))
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func save(_ bottle: Bottle) throws {
        let location = location(of: bottle)
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        try JSONEncoder.bottles.encode(bottle).write(to: location.metadata, options: .atomic)
    }

    /// Creates the prefix with `wineboot`. Isolated bottles are created inside their sandbox, then
    /// hardened, and their clean state is kept as an APFS clone for "Reset to clean".
    public func create(_ bottle: Bottle, engine: Engine) async throws {
        let location = location(of: bottle)
        let fm = FileManager.default
        for folder in [location.directory, location.prefix, location.home] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var bottle = bottle
        try save(bottle)
        try await runSetup(["wineboot", "--init"], bottle: bottle, engine: engine, name: "create")
        bottle.runtimeModules = RuntimeModules.fingerprint(runtime: engine.root)
        try save(bottle)
        if bottle.kind == .isolated {
            try PrefixHardening.apply(prefix: location.prefix)
            try snapshotClean(bottle)
        }
    }

    /// Refreshes the prefix after the runtime changed (new Wine modules need placeholders in system32).
    @discardableResult
    public func update(_ bottle: Bottle, engine: Engine) async throws -> Bottle {
        // --restart skips the Run keys and Startup folder: a plain --update starts every program that
        // registered itself to start with Windows (Steam -silent), and the session never ends.
        try await runSetup(["wineboot", "--update", "--restart"], bottle: bottle, engine: engine, name: "update")
        if bottle.kind == .isolated { try PrefixHardening.apply(prefix: location(of: bottle).prefix) }
        var bottle = bottle
        bottle.runtimeModules = RuntimeModules.fingerprint(runtime: engine.root)
        try save(bottle)
        return bottle
    }

    /// What `prepareForLaunch` did.
    public enum Preparation: Equatable, Sendable {
        case upToDate
        /// Ran `wineboot --update` because the runtime's modules changed.
        case updated
        /// The runtime changed but the bottle is running, so updating waits for the next launch.
        case updateDeferred
    }

    /// Brings the bottle up to date with `engine` before a launch: `wineboot --update` when the
    /// runtime's Windows modules changed since the prefix was last booted. A running bottle is left
    /// alone (updating would wait for its programs to quit); the next launch on an idle bottle catches up.
    public func prepareForLaunch(_ bottle: Bottle, engine: Engine) async throws -> Preparation {
        guard bottle.runtimeModules != RuntimeModules.fingerprint(runtime: engine.root) else { return .upToDate }
        guard !WineServer.isRunning(prefix: location(of: bottle).prefix, base: paths.wineServerDirectory) else {
            return .updateDeferred
        }
        try await update(bottle, engine: engine)
        return .updated
    }

    /// Replaces an isolated bottle's Windows drive with its clean snapshot, discarding everything since.
    public func resetToClean(_ bottle: Bottle, engine: Engine) throws {
        guard bottle.kind == .isolated else { throw StoreError.notIsolated }
        let location = location(of: bottle)
        guard FileManager.default.fileExists(atPath: location.cleanSnapshot.path) else { throw StoreError.noCleanSnapshot }
        let context = WineContext(engine: engine, bottle: bottle, location: location, paths: paths, hostEnvironment: hostEnvironment)
        ProcessRunner.stopSession(environment: try LaunchPlanner.plan(wineArguments: [], in: context).environment,
                                  wineserver: engine.wineserver)
        try FileManager.default.removeItem(at: location.prefix)
        try clone(location.cleanSnapshot, to: location.prefix)
        // The snapshot may predate runtime changes; the next launch runs wineboot --update.
        var bottle = bottle
        bottle.runtimeModules = nil
        try save(bottle)
    }

    /// Adds a bottle folder made elsewhere (another data folder, a backup) as an APFS clone.
    /// It keeps its id, so the same bottle can't be added twice.
    @discardableResult
    public func importBottle(from folder: URL) throws -> Bottle {
        let source = BottleLocation(directory: folder)
        let bottle = try JSONDecoder.bottles.decode(Bottle.self, from: Data(contentsOf: source.metadata))
        let destination = location(of: bottle).directory
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw StoreError.alreadyExists(bottle.name) }
        try FileManager.default.createDirectory(at: paths.bottles, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: folder, to: destination)  // clonefile on APFS
        return bottle
    }

    /// Clones a program from outside into the bottle's Downloads folder, so an isolated bottle (which
    /// sees only its own C: drive) can run it. Sibling files sharing its name come along, for
    /// installers split into `setup.exe` + `setup-1.bin`. Returns the program's new location.
    public func importProgram(_ program: URL, into bottle: Bottle) throws -> URL {
        let fm = FileManager.default
        let downloads = windowsUserFolder(of: bottle).appending(path: "Downloads", directoryHint: .isDirectory)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let stem = program.deletingPathExtension().lastPathComponent.lowercased()
        let siblings = (try? fm.contentsOfDirectory(at: program.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        // "setup.exe" brings "setup-1.bin" and "setup.bin", not "setup_other_game.exe".
        let files = siblings.filter { file in
            let name = file.lastPathComponent.lowercased()
            return name.hasPrefix(stem) && [".", "-"].contains(name.dropFirst(stem.count).first.map(String.init))
                && (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        for file in Set(files + [program]) {
            let target = downloads.appending(path: file.lastPathComponent)
            // Imported before; same size alone isn't enough, the file may have changed since.
            if fileSize(target) != nil, fileSize(target) == fileSize(file), fm.contentsEqual(atPath: target.path, andPath: file.path) { continue }
            try? fm.removeItem(at: target)
            try fm.copyItem(at: file, to: target)
        }
        return downloads.appending(path: program.lastPathComponent)
    }

    /// `drive_c/users/<name>`: the Windows user's own folder (Wine names it after the Mac user,
    /// winecx always `crossover`).
    public func windowsUserFolder(of bottle: Bottle) -> URL {
        Self.windowsUserFolder(inPrefix: location(of: bottle).prefix)
    }

    static func windowsUserFolder(inPrefix prefix: URL) -> URL {
        let users = prefix.appending(path: "drive_c/users", directoryHint: .isDirectory)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []).filter { $0 != "Public" && !$0.hasPrefix(".") }
        return users.appending(path: names.contains("crossover") ? "crossover" : names.sorted().first ?? "crossover",
                               directoryHint: .isDirectory)
    }

    private func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    func snapshotClean(_ bottle: Bottle) throws {
        let location = location(of: bottle)
        try? FileManager.default.removeItem(at: location.cleanSnapshot)
        try clone(location.prefix, to: location.cleanSnapshot)
    }

    /// Runs a Wine setup command in the bottle (sandboxed for isolated bottles) and waits for the
    /// bottle's wineserver to exit so the prefix is complete on disk.
    private func runSetup(_ arguments: [String], bottle: Bottle, engine: Engine, name: String) async throws {
        try ensureWineServerBase()
        let location = location(of: bottle)
        let context = WineContext(engine: engine, bottle: bottle, location: location, paths: paths, hostEnvironment: hostEnvironment)
        // Skip the Mono/Gecko install prompts; the app installs Mono itself when a game needs .NET.
        let plan = try LaunchPlanner.plan(wineArguments: arguments, in: context, dllOverrides: ["mscoree": "", "mshtml": ""])
        let log = paths.logsRoot.appending(path: "bottles/\(bottle.id.uuidString)/\(name).log")
        let result = try await ProcessRunner.run(plan, log: log, wineserver: engine.wineserver)
        // Setup only runs on idle bottles, so whatever still runs after a minute is the setup's own
        // leftovers; stop it rather than wait forever.
        if !ProcessRunner.waitForSession(environment: plan.environment, wineserver: engine.wineserver, timeout: .seconds(60)) {
            ProcessRunner.stopSession(environment: plan.environment, wineserver: engine.wineserver)
            ProcessRunner.waitForSession(environment: plan.environment, wineserver: engine.wineserver, timeout: .seconds(10))
        }
        guard result.status == 0 else { throw StoreError.setupFailed(outcome: result.outcome, log: log.path) }
    }

    /// Wine requires `/tmp/.wine-<uid>` to be private; isolated bottles can't create it themselves,
    /// and macOS empties `/tmp` on restart.
    func ensureWineServerBase() throws {
        try FileManager.default.createDirectory(
            at: paths.wineServerDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    /// APFS clone: instant, and uses no extra space until files change.
    private func clone(_ source: URL, to destination: URL) throws {
        guard clonefile(source.path, destination.path, 0) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path,
                                                          NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
    }
}

extension JSONEncoder {
    static var bottles: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var bottles: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
