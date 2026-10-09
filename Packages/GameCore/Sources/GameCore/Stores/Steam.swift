import Foundation

/// Steam inside a bottle: finding it and its installed games, launching them the way that works
/// under Wine, and keeping its web helper usable.
public enum Steam {
    public static let store = "steam"

    /// Steam ignores every flag after a literal `--`; these keep it from restoring its own web helper.
    public static let clientArguments = ["-noverifyfiles", "-norepairfiles"]

    /// Settings tested on this Mac, by Steam app id; the detected backend covers everything else.
    public static let testedProfiles: [String: GameProfile] = [
        // Black Myth: Wukong Benchmark Tool: DX12 through D3DMetal (GPTK 3.0) with MetalFX (pick DLSS in
        // the game), Retina on. In game: Super Resolution ~34, Medium with GI/Reflections/Shadows Low,
        // Frame Generation off (it crashes on DX12).
        "3132990": GameProfile(backendOverride: .d3dmetal, metalFX: true, retinaMode: true),
        // Red Dead Redemption 2: DX12 through D3DMetal (GPTK 3.0) with MetalFX, Retina off. Its in-game
        // settings start from RockstarLauncher.rdr2TestedSettings.
        "1174180": GameProfile(backendOverride: .d3dmetal, metalFX: true),
        // Emily is Away: 32-bit, DX11 through DXVK.
        "417860": GameProfile(backendOverride: .dxvk),
    ]

    /// Games tested with Corkscrew, shown in the library before they're installed: their button opens
    /// their store page in Steam, and they start with their tested settings once downloaded.
    public static let testedGames: [(appID: String, name: String)] = [
        ("1174180", "Red Dead Redemption 2"),
        ("3132990", "Black Myth: Wukong Benchmark Tool"),
        ("417860", "Emily is Away"),
    ]

    public static func isTested(appID: String) -> Bool { testedGames.contains { $0.appID == appID } }

    /// Starts Steam without its window when launching a game: under Wine the window is drawn in
    /// software and costs one to two CPU cores the game could use. Steam's icon stays in the menu bar.
    public static let silentArgument = "-silent"

    /// Steam's own settings. Games started from Steam's window inherit them, so they follow the
    /// tested setup of the main game here (the Wukong benchmark), except Retina mode: Steam's window
    /// is drawn by the CPU, and at Retina resolution that's four times the pixels.
    public static var clientProfile: GameProfile {
        var profile = testedProfiles["3132990"]!
        profile.retinaMode = false
        profile.arguments = clientArguments
        return profile
    }

    /// Bumped when the settings found entries get change; `upgraded(_:from:)` brings entries saved
    /// with older settings up to date once.
    public static let settingsVersion = 2

    /// An entry saved with older settings, brought up to date. Only the changed settings are touched,
    /// so the user's other choices stay.
    static func upgraded(_ game: Game, from version: Int) -> Game {
        guard let item = game.store, item.store == store else { return game }
        var game = game
        if version < 2 {
            if item.appID == nil {
                game.profile.retinaMode = false
            } else if !game.profile.arguments.contains(silentArgument) {
                let index = game.profile.arguments.firstIndex(of: "-applaunch") ?? game.profile.arguments.endIndex
                game.profile.arguments.insert(silentArgument, at: index)
            }
        }
        return game
    }

    /// A game Steam has in a library folder, from `steamapps/appmanifest_<id>.acf`: installed, or
    /// still downloading.
    public struct App: Equatable, Sendable {
        public var appID: String
        public var name: String
        public var installFolder: URL
        /// The manifest's `StateFlags`; bit 2 (4) is "fully installed". Missing counts as installed.
        public var stateFlags: Int = 4

        public var isInstalled: Bool { stateFlags & 4 != 0 }
    }

    /// Where a game in the library stands in Steam. Uninstalled games keep their library entry, and
    /// with it their settings, for when they're downloaded again.
    public enum InstallState: Sendable, Equatable {
        case installed
        /// Steam has a manifest for it but hasn't finished the first download (or a re-download).
        case downloading
        case notInstalled
    }

    /// The state of every game Steam knows in the bottle, by `StoreItem.key(in:)`. Games not in it
    /// aren't installed.
    public static func installStates(for bottle: Bottle, prefix: URL) -> [String: InstallState] {
        guard let root = root(inPrefix: prefix) else { return [:] }
        var states: [String: InstallState] = [:]
        for app in installedApps(steamRoot: root, prefix: prefix) {
            states[StoreItem(store: store, appID: app.appID).key(in: bottle.id)] = app.isInstalled ? .installed : .downloading
        }
        return states
    }

    /// Opens the game's store page (with its Install or Download button) in Steam: the
    /// `steam://` link the way Steam's own link handler passes it, `steam.exe -- "<link>"`.
    public static func storePageArguments(appID: String) -> [String] {
        clientArguments + ["--", "steam://store/\(appID)"]
    }

    /// `C:\Program Files (x86)\Steam` in the bottle, if Steam is installed there.
    public static func root(inPrefix prefix: URL) -> URL? {
        ["drive_c/Program Files (x86)/Steam", "drive_c/Program Files/Steam"]
            .map { prefix.appending(path: $0, directoryHint: .isDirectory) }
            .first { FileManager.default.fileExists(atPath: $0.appending(path: "steam.exe").path) }
    }

    /// Valve's Steam installer for Windows. Not pinned by checksum: Valve updates it in place.
    public static let installerURL = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!

    public enum InstallError: Error, Equatable, CustomStringConvertible {
        case failed(status: Int32, log: String)
        case updateFailed(log: String)

        public var description: String {
            switch self {
            case .failed(let status, let log): "Steam's installer didn't finish (exit \(status)); see \(log)"
            case .updateFailed(let log): "Steam couldn't download the rest of itself (is the Mac online?); see \(log)"
            }
        }
    }

    /// Whether Steam has downloaded the rest of itself: the installer leaves only a bootstrapper, and
    /// without `steamui.dll` Steam stops with "Failed to load steamui.dll".
    public static func isBootstrapped(steamRoot: URL) -> Bool {
        FileManager.default.fileExists(atPath: steamRoot.appending(path: "steamui.dll").path)
    }

    /// The flags Steam must not get before it's bootstrapped: `-noverifyfiles` also skips its
    /// first download.
    static func launchArguments(_ arguments: [String], steamRoot: URL) -> [String] {
        isBootstrapped(steamRoot: steamRoot) ? arguments : arguments.filter { !clientArguments.contains($0) }
    }

    /// Installs Steam into `bottle` with Valve's installer, silently (`/S`), and returns its
    /// `steam.exe`. An isolated bottle gets the installer copied onto its own drive first.
    @discardableResult
    public static func install(
        installer: URL, bottle: Bottle, engine: Engine, paths: AppPaths, log: URL,
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> URL {
        let store = BottleStore(paths: paths, hostEnvironment: hostEnvironment)
        _ = try await store.prepareForLaunch(bottle, engine: engine)
        let program = bottle.kind == .isolated ? try store.importProgram(installer, into: bottle) : installer
        let context = WineContext(engine: engine, bottle: bottle, location: store.location(of: bottle),
                                  paths: paths, hostEnvironment: hostEnvironment)
        let plan = try LaunchPlanner.plan(wineArguments: [program.path, "/S"], in: context)
        let result = try await ProcessRunner.run(plan, log: log, wineserver: engine.wineserver)
        // Let the bottle settle so the files are on disk; a Steam the installer started keeps running.
        ProcessRunner.waitForSession(environment: plan.environment, wineserver: engine.wineserver, timeout: .seconds(60))
        guard result.status == 0, let root = root(inPrefix: context.location.prefix) else {
            throw InstallError.failed(status: result.status, log: log.path)
        }
        try await bootstrap(steamRoot: root, context: context, log: log.deletingLastPathComponent().appending(path: "steam-update.log"))
        return root.appending(path: "steam.exe")
    }

    /// Starts Steam once so it downloads the rest of itself (about 240 MB, in two rounds with a restart
    /// between), waits until its interface starts (`steamwebhelper.exe`: only once every update is
    /// in), then stops it. The first launch from the library then goes straight to signing in, with
    /// the web helper wrapper in place.
    static func bootstrap(steamRoot: URL, context: WineContext, log: URL, timeout: Duration = .seconds(1800)) async throws {
        let plan = try LaunchPlanner.plan(wineArguments: [steamRoot.appending(path: "steam.exe").path], in: context)
        let wineserver = context.engine.wineserver
        Task { _ = try? await ProcessRunner.run(plan, log: log, wineserver: wineserver) }
        let updaterLog = steamRoot.appending(path: "logs/bootstrap_log.txt")
        func updated() -> Bool {
            isBootstrapped(steamRoot: steamRoot)
                && BottleProcesses.list(prefix: context.location.prefix).contains { $0.program.hasSuffix("\\steamwebhelper.exe") }
        }
        defer { ProcessRunner.stopSession(environment: plan.environment, wineserver: wineserver) }
        let started = ContinuousClock.now
        while !updated() {
            // Steam exits (42) to restart itself after updating, so its own exit means nothing; it has
            // given up once the whole bottle has stopped.
            let stopped = ContinuousClock.now - started > .seconds(15)
                && !WineServer.isRunning(prefix: context.location.prefix, base: context.paths.wineServerDirectory)
            if stopped || ContinuousClock.now - started > timeout { throw InstallError.updateFailed(log: updaterLog.path) }
            try await Task.sleep(for: .seconds(2))
        }
    }

    public static func isClient(_ executable: URL) -> Bool {
        executable.lastPathComponent.lowercased() == "steam.exe"
    }

    /// Games in every Steam library folder of the bottle, installed or downloading.
    public static func installedApps(steamRoot: URL, prefix: URL) -> [App] {
        let libraries = [steamRoot] + libraryFolders(steamRoot: steamRoot, prefix: prefix).filter {
            $0.standardizedFileURL.resolvingSymlinksInPath() != steamRoot.standardizedFileURL.resolvingSymlinksInPath()
        }
        var apps: [App] = []
        for library in libraries {
            let steamapps = library.appending(path: "steamapps", directoryHint: .isDirectory)
            let files = (try? FileManager.default.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" {
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      let appID = value("appid", in: text), let name = value("name", in: text),
                      let folder = value("installdir", in: text) else { continue }
                apps.append(App(appID: appID, name: name,
                                installFolder: steamapps.appending(path: "common/\(folder)", directoryHint: .isDirectory),
                                stateFlags: value("StateFlags", in: text).flatMap { Int($0) } ?? 4))
            }
        }
        return apps
    }

    /// The program that represents a game (for its icon and backend): a top-level `.exe` named like
    /// the game or its folder, otherwise the biggest one. Nil for tools without one (Steamworks Shared).
    public static func mainExecutable(of app: App) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: app.installFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let skipped = ["unins", "setup", "crash", "redist", "vcredist", "dxsetup", "dotnet", "uninstall"]
        let programs = files.filter { file in
            let name = file.lastPathComponent.lowercased()
            return name.hasSuffix(".exe") && !skipped.contains(where: name.contains)
        }
        let wanted = Set([app.name, app.installFolder.lastPathComponent].map(normalized))
        if let named = programs.first(where: { wanted.contains(normalized($0.deletingPathExtension().lastPathComponent)) }) {
            return named
        }
        return programs.max { size($0) < size($1) }
    }

    /// Library entries for Steam in a bottle: Steam itself, and each installed game launched through
    /// Steam (`-silent -applaunch`) with its tested settings, or the backend detected from its program.
    /// Games still downloading are added once they're installed (their program isn't there yet).
    /// Entries whose `Game.storeKey` is in `known` are skipped (detection reads the game's files).
    /// With `includeTested`, the tested games that aren't installed come too (`testedGames`).
    public static func libraryEntries(
        for bottle: Bottle, prefix: URL, excluding known: Set<String> = [], includeTested: Bool = false
    ) -> [Game] {
        guard let root = root(inPrefix: prefix) else { return [] }
        let client = root.appending(path: "steam.exe")
        var games = [Game(name: "Steam", executable: client, bottleID: bottle.id, profile: clientProfile,
                          store: StoreItem(store: store))]
        for app in installedApps(steamRoot: root, prefix: prefix) where app.isInstalled {
            let key = StoreItem(store: store, appID: app.appID).key(in: bottle.id)
            guard !known.contains(key), let program = mainExecutable(of: app) else { continue }
            var profile = testedProfiles[app.appID] ?? detectedProfile(for: program)
            profile.arguments = clientArguments + [silentArgument, "-applaunch", app.appID]
            games.append(Game(name: app.name, executable: client, bottleID: bottle.id, profile: profile,
                              store: StoreItem(store: store, appID: app.appID), iconSource: program))
        }
        if includeTested {
            let listed = Set(games.compactMap(\.store?.appID))
            for tested in testedGames where !listed.contains(tested.appID) {
                var profile = testedProfiles[tested.appID] ?? GameProfile()
                profile.arguments = clientArguments + [silentArgument, "-applaunch", tested.appID]
                games.append(Game(name: tested.name, executable: client, bottleID: bottle.id, profile: profile,
                                  store: StoreItem(store: store, appID: tested.appID)))
            }
        }
        return games.filter { !known.contains($0.storeKey!) }
    }

    /// The main program of each installed game, by app id: for the icons of entries added before
    /// their game was downloaded.
    public static func installedPrograms(prefix: URL) -> [String: URL] {
        guard let root = root(inPrefix: prefix) else { return [:] }
        var programs: [String: URL] = [:]
        for app in installedApps(steamRoot: root, prefix: prefix) where app.isInstalled {
            programs[app.appID] = mainExecutable(of: app)
        }
        return programs
    }

    /// The backend for the game's own program, written down so Steam (which the game inherits its
    /// environment from) starts with it. MetalFX comes along with D3DMetal; it only acts when the game
    /// offers DLSS and the player picks it.
    static func detectedProfile(for program: URL) -> GameProfile {
        guard let inspection = try? GameDetector.inspect(executable: program) else { return GameProfile() }
        let backend = inspection.recommendedBackend
        return GameProfile(backendOverride: backend, metalFX: backend == .d3dmetal)
    }

    /// Puts our wrapper in front of Steam's `steamwebhelper.exe` (the real one becomes
    /// `steamwebhelper_real.exe`), so Steam's window paints and its network service works under Wine.
    /// Steam updates restore the original, so this runs before every Steam launch. Returns true when
    /// it moved Steam's own helper aside; false when the wrapper was already there or Steam hasn't
    /// downloaded its web helper yet.
    @discardableResult
    public static func installWebHelperWrapper(steamRoot: URL, wrapper: URL) throws -> Bool {
        // Every CEF build Steam has (cef.win64, cef.win7x64, …): which one it runs depends on its version.
        let cefRoot = steamRoot.appending(path: "bin/cef", directoryHint: .isDirectory)
        let builds = (try? FileManager.default.contentsOfDirectory(at: cefRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        var installed = false
        for cef in builds.sorted(by: { $0.path < $1.path }) {
            if try installWebHelperWrapper(cef: cef, wrapper: wrapper) { installed = true }
        }
        return installed
    }

    private static func installWebHelperWrapper(cef: URL, wrapper: URL) throws -> Bool {
        let fm = FileManager.default
        let helper = cef.appending(path: "steamwebhelper.exe")
        let real = cef.appending(path: "steamwebhelper_real.exe")
        guard fm.fileExists(atPath: helper.path) else { return false }
        if fm.contentsEqual(atPath: helper.path, andPath: wrapper.path) { return false }
        if isWrapper(helper) {
            // Another build of the wrapper (each build has its own timestamp): swap in this one, and
            // never move it over the real helper.
            try fm.removeItem(at: helper)
            try fm.copyItem(at: wrapper, to: helper)
            return false
        }
        // First install, or an update restored Steam's helper: keep the newest real one.
        if fm.fileExists(atPath: real.path) { try fm.removeItem(at: real) }
        try fm.moveItem(at: helper, to: real)
        try fm.copyItem(at: wrapper, to: helper)
        return true
    }

    /// Our wrapper names the program it starts; Steam's own helper doesn't.
    static func isWrapper(_ file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped), data.count < 4 << 20 else { return false }
        return data.range(of: Data("steamwebhelper_real.exe".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })) != nil
    }

    // MARK: Steam's files

    /// Steam library folders listed in `steamapps/libraryfolders.vdf`, as paths in the bottle.
    static func libraryFolders(steamRoot: URL, prefix: URL) -> [URL] {
        let file = steamRoot.appending(path: "steamapps/libraryfolders.vdf")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return values("path", in: text).compactMap { windowsPath($0, prefix: prefix) }
    }

    /// `C:\Games\Steam` → `<prefix>/dosdevices/c:/Games/Steam` (the drive links point into the bottle).
    static func windowsPath(_ path: String, prefix: URL) -> URL? {
        let parts = path.split(separator: "\\", omittingEmptySubsequences: true).map(String.init)
        guard let drive = parts.first, drive.count == 2, drive.hasSuffix(":") else { return nil }
        return parts.dropFirst().reduce(prefix.appending(path: "dosdevices/\(drive.lowercased())", directoryHint: .isDirectory)) {
            $0.appending(path: $1, directoryHint: .isDirectory)
        }
    }

    /// The first `"key"  "value"` pair in Valve's KeyValues text.
    static func value(_ key: String, in text: String) -> String? { values(key, in: text).first }

    static func values(_ key: String, in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let quoted = line.split(separator: "\"", omittingEmptySubsequences: false)
            // `\t"key"\t\t"value"` splits into ["\t", "key", "\t\t", "value", ""].
            guard quoted.count >= 5, quoted[1].lowercased() == key.lowercased() else { return nil }
            return quoted[3].replacingOccurrences(of: "\\\\", with: "\\")
        }
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }
}
