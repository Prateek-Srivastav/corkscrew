import AppKit
import Foundation
import GameCore
import Observation

/// The app's state: library, bottles, runtimes and running launches. Everything slow (Wine setup,
/// disk images, clones) runs off the main thread; the model only records what happened.
@Observable
final class AppModel {
    static let shared = AppModel()

    /// One launch of a game (or a "Run once" program) and how it's going.
    struct Session {
        enum Status: Equatable {
            case preparing
            case running
            case exited(Int32)
            case stopped
            case failed(String)
        }

        var game: Game
        var status: Status = .preparing
        var log: URL?
        var notes: [String] = []
        var task: Task<Void, Never>?
        /// Not in the library: started with "Run once".
        var isTransient: Bool

        var isActive: Bool { status == .preparing || status == .running }
    }

    let paths: AppPaths
    private(set) var library = Library()
    var games: [Game] { library.games }
    private(set) var bottles: [Bottle] = []
    private(set) var runtimes: [RuntimeManifest] = []
    private(set) var components: [String] = []
    /// Bottles whose wineserver is up, refreshed every couple of seconds.
    private(set) var runningBottles: Set<UUID> = []
    /// Steam games' install states by `Game.storeKey`; nil until the first scan.
    private(set) var storeStates: [String: Steam.InstallState]?
    private(set) var sessions: [UUID: Session] = [:]
    /// Programs opened from Finder, dropped on the window or picked with Add Program, waiting for
    /// the user to choose "Run Once" or "Add to Library".
    var openRequests: [URL] = []
    /// What the app is busy with (shown at the bottom of the window), nil when idle.
    private(set) var activity: String?
    var errorMessage: String?

    var isSetUp: Bool { !runtimes.isEmpty && !bottles.isEmpty }

    init(paths: AppPaths = AppModel.configuredPaths) {
        self.paths = paths
        reload()
        Task { await setUpAutomatically() }
        Task { [weak self] in
            var tick = 0
            while let self {
                self.refreshRunningBottles()
                // While Steam may be installing or uninstalling games, look at its manifests now and then.
                tick += 1
                if tick % 15 == 0, !self.runningBottles.isEmpty { self.syncStores() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // Back from Steam (or Finder): pick up games installed or uninstalled meanwhile.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncStores() }
        }
    }

    /// `~/Library/…/Corkscrew`, or one folder for everything when the `DataRoot` default is set
    /// (`defaults write io.github.prateek-srivastav.Corkscrew DataRoot <folder>`, or `-DataRoot <folder>` at launch),
    /// e.g. the CLI's `build/dev-data`.
    static var configuredPaths: AppPaths {
        guard let root = UserDefaults.standard.string(forKey: "DataRoot"), !root.isEmpty else { return .standard }
        return .rooted(at: URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true))
    }

    func reload() {
        do {
            library = try LibraryStore(paths: paths).load()
            bottles = try BottleStore(paths: paths).list()
        } catch {
            errorMessage = Self.describe(error)
        }
        runtimes = RuntimeStore(paths: paths).list()
        components = ComponentCatalog.staged(in: paths.components)
        refreshRunningBottles()
        syncStores()
    }

    // MARK: Automatic setup

    /// First run without clicks: in a development checkout the app finds the runtime and components
    /// the scripts built (`<repo>/build/runtime`, `build/components`) and adds them as APFS clones,
    /// then creates the "Games" bottle if there's no bottle yet.
    private func setUpAutomatically() async {
        let paths = self.paths
        if let build = Self.developmentBuildFolder() {
            let installed = Set(runtimes.map(\.id))
            let runtimeFolders = ((try? FileManager.default.contentsOfDirectory(at: build.appending(path: "runtime"), includingPropertiesForKeys: nil)) ?? [])
                .filter { (try? RuntimeStore.manifest(in: $0)).map { !installed.contains($0.id) } ?? false }
            let components = build.appending(path: "components", directoryHint: .isDirectory)
            let newComponents = ComponentCatalog.staged(in: components).filter { !self.components.contains($0) }
            if !runtimeFolders.isEmpty || !newComponents.isEmpty {
                await perform("Adding the Wine runtime and graphics components from \(build.path)…") {
                    for folder in runtimeFolders { try RuntimeStore(paths: paths).install(directory: folder) }
                    try ComponentCatalog.importComponents(from: components, into: paths.components)
                }
            }
        }
        if bottles.isEmpty, !runtimes.isEmpty {
            createBottle(name: "Games", kind: .standard)
        }
    }

    /// `<repo>/build` when the app runs from a checkout that has built the runtime (the app itself is
    /// built into `build/DerivedData`, possibly inside a worktree of the repo).
    private static func developmentBuildFolder() -> URL? {
        var folder = Bundle.main.bundleURL.deletingLastPathComponent()
        while folder.path != "/" {
            let build = folder.appending(path: "build", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: build.appending(path: "runtime").path) { return build }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: Stores

    @ObservationIgnored private var isSyncingStores = false
    @ObservationIgnored private var storesChangedWhileSyncing = false

    /// Adds Steam, and the games installed through it, from every bottle: with the tested settings,
    /// or the backend detected from each game. Entries the user removed stay removed. Uninstalled
    /// games stay too, with their settings, shown as not downloaded.
    private func syncStores() {
        guard !isSyncingStores else {
            storesChangedWhileSyncing = true
            return
        }
        isSyncingStores = true
        let paths = self.paths
        let bottles = self.bottles
        let known = Set(library.games.compactMap(\.storeKey)).union(library.removedStoreItems)
        Task {
            let (found, states) = await Task.detached(priority: .utility) {
                var found: [Game] = []
                var states: [String: Steam.InstallState] = [:]
                for bottle in bottles {
                    let prefix = BottleLocation(bottleID: bottle.id, paths: paths).prefix
                    found += Steam.libraryEntries(for: bottle, prefix: prefix, excluding: known)
                    states.merge(Steam.installStates(for: bottle, prefix: prefix)) { $1 }
                }
                return (found, states)
            }.value
            isSyncingStores = false
            if storeStates != states { storeStates = states }
            if !library.addMissing(found).isEmpty { saveLibrary() }
            if storesChangedWhileSyncing {
                storesChangedWhileSyncing = false
                syncStores()
            }
        }
    }

    private func refreshRunningBottles() {
        let running = Set(bottles.filter { Launcher.isRunning($0, paths: paths) }.map(\.id))
        guard running != runningBottles else { return }
        runningBottles = running
        syncStores()
    }

    // MARK: Library

    func bottle(for game: Game) -> Bottle? { bottles.first { $0.id == game.bottleID } }

    /// Installed, unless it's a Steam game Steam no longer has (or is still downloading). Programs
    /// added by hand, and everything before the first scan, count as installed.
    func installState(of game: Game) -> Steam.InstallState {
        guard game.store?.appID != nil, let key = game.storeKey, let storeStates else { return .installed }
        return storeStates[key] ?? .notInstalled
    }

    @ObservationIgnored private var icons: [UUID: NSImage?] = [:]

    func icon(for game: Game) -> NSImage? {
        if let cached = icons[game.id] { return cached }
        let image = LibraryStore(paths: paths).icon(for: game).flatMap(NSImage.init(data:))
        icons[game.id] = image
        return image
    }

    func update(_ game: Game) {
        guard let index = library.games.firstIndex(where: { $0.id == game.id }), library.games[index] != game else { return }
        library.games[index] = game
        saveLibrary()
    }

    /// Takes the game out of the library; Steam entries aren't added back.
    func remove(_ game: Game) {
        library.remove(game.id)
        LibraryStore(paths: paths).removeCachedIcon(for: game)
        saveLibrary()
    }

    private func saveLibrary() {
        do { try LibraryStore(paths: paths).save(library) } catch { errorMessage = Self.describe(error) }
    }

    // MARK: Opening programs

    func open(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        for url in urls where url.scheme == "corkscrew" { handleLink(url) }
        let programs = files.filter { ["exe", "msi"].contains($0.pathExtension.lowercased()) }
        if programs.count < files.count { errorMessage = "Only Windows programs (.exe) and installers (.msi) can be opened." }
        openRequests += programs.filter { !openRequests.contains($0) }
    }

    /// `corkscrew://launch/<game id>` and `corkscrew://stop/<game id>`, for shortcuts and scripts.
    private func handleLink(_ url: URL) {
        guard let id = UUID(uuidString: url.lastPathComponent), let game = games.first(where: { $0.id == id }) else {
            errorMessage = "No game in the library matches \(url.absoluteString)."
            return
        }
        switch url.host() {
        case "launch": play(game)
        case "stop": stop(game)
        default: errorMessage = "Unknown link \(url.absoluteString)."
        }
    }

    /// The bottle a program already lives in, if it's inside one.
    func bottle(containing program: URL) -> Bottle? {
        let path = program.standardizedFileURL.resolvingSymlinksInPath().path
        return bottles.first { bottle in
            let prefix = BottleLocation(bottleID: bottle.id, paths: paths).prefix.standardizedFileURL.resolvingSymlinksInPath().path
            return path.hasPrefix(prefix + "/")
        }
    }

    /// Where a new program goes unless the user picks another bottle: the bottle it's already in,
    /// otherwise the standard "Games" bottle (or any standard one).
    func suggestedBottle(for program: URL) -> Bottle? {
        bottle(containing: program)
            ?? bottles.first { $0.kind == .standard && $0.name == "Games" }
            ?? bottles.first { $0.kind == .standard }
            ?? bottles.first
    }

    /// Whether running `program` in `bottle` needs a copy inside it first (isolated bottles only see their own drive).
    func needsImport(_ program: URL, into bottle: Bottle) -> Bool {
        bottle.kind == .isolated && self.bottle(containing: program)?.id != bottle.id
    }

    /// Adds the program to the library (copying it into an isolated bottle first) and returns it.
    @discardableResult
    func addToLibrary(_ program: URL, bottle: Bottle, name: String? = nil) async -> Game? {
        guard let executable = await prepareProgram(program, for: bottle) else { return nil }
        let game = Game(name: name ?? Game.defaultName(for: executable), executable: executable, bottleID: bottle.id)
        library.games.append(game)
        saveLibrary()
        return game
    }

    /// Runs the program without adding it to the library.
    func runOnce(_ program: URL, bottle: Bottle) async {
        guard let executable = await prepareProgram(program, for: bottle) else { return }
        let game = Game(name: executable.deletingPathExtension().lastPathComponent, executable: executable, bottleID: bottle.id)
        play(game, transient: true)
    }

    private func prepareProgram(_ program: URL, for bottle: Bottle) async -> URL? {
        guard needsImport(program, into: bottle) else { return program }
        let paths = self.paths
        return await perform("Copying \(program.lastPathComponent) into \(bottle.name)…") {
            try BottleStore(paths: paths).importProgram(program, into: bottle)
        }
    }

    // MARK: Launching

    func session(for game: Game) -> Session? { sessions[game.id] }

    /// Running "Run once" programs, newest first.
    var transientSessions: [Session] {
        sessions.values.filter { $0.isTransient && $0.isActive }.sorted { $0.game.addedAt > $1.game.addedAt }
    }

    /// Starts the game; a Steam game that isn't downloaded opens its Steam page instead.
    func play(_ game: Game, transient: Bool = false) {
        guard sessions[game.id]?.isActive != true else { return }
        if installState(of: game) != .installed {
            openInSteam(game)
            return
        }
        if !transient {
            var played = game
            played.lastPlayedAt = .now
            update(played)
        }
        start(game, transient: transient)
    }

    /// Opens a Steam game's store page in Steam, to download it (again). Steam starts as its library
    /// entry, with its own settings; when the bottle already runs, the link goes to the Steam there.
    func openInSteam(_ game: Game) {
        guard let appID = game.store?.appID else { return }
        let entry = games.first { $0.bottleID == game.bottleID && $0.store == StoreItem(store: Steam.store) }
        var steam = entry ?? Game(name: "Steam", executable: game.executable, bottleID: game.bottleID,
                                  profile: Steam.clientProfile, store: StoreItem(store: Steam.store))
        steam.profile.arguments = Steam.storePageArguments(appID: appID)
        if runningBottles.contains(game.bottleID) || sessions[steam.id]?.isActive == true {
            // Steam (or something) runs there already: this steam.exe only hands the link over.
            forward(steam)
        } else {
            start(steam, transient: entry == nil)
        }
    }

    private func start(_ game: Game, transient: Bool) {
        guard let bottle = bottle(for: game) else {
            errorMessage = "\(game.name)'s bottle is gone. Add the program again to pick another one."
            return
        }
        let paths = self.paths
        let steamWasRunning = game.store?.appID != nil && runningBottles.contains(bottle.id)
        sessions[game.id] = Session(game: game, isTransient: transient)
        sessions[game.id]?.task = Task { [weak self] in
            do {
                guard let engine = try RuntimeStore(paths: paths).engine(id: bottle.engineID) else {
                    throw AppError("No Wine runtime is installed. Add one under Setup.")
                }
                let prepared = try await Launcher.prepare(gameID: game.id, executable: game.executable, profile: game.profile,
                                                          bottle: bottle, engine: engine, paths: paths,
                                                          steamWebHelperWrapper: Self.steamWebHelperWrapper)
                try Task.checkCancellation()
                self?.sessions[game.id]?.log = prepared.log
                self?.sessions[game.id]?.notes = prepared.notes
                    + (steamWasRunning ? ["Steam was already running in this bottle, so the game starts with Steam's settings, not its own."] : [])
                    + (prepared.inspection?.antiCheat.map { "\($0.kind.rawValue) found (\($0.evidence)): "
                        + ($0.severity == .blocksLaunch ? "this game won't run under Wine." : "online play may not work.") } ?? [])
                self?.sessions[game.id]?.status = .running
                if game.profile.performanceOverlay { Self.startOverlay(prefix: prepared.context.location.prefix) }
                let result = try await Launcher.run(prepared)
                self?.sessions[game.id]?.status = Task.isCancelled ? .stopped : .exited(result.status)
            } catch is CancellationError {
                self?.sessions[game.id]?.status = .stopped
            } catch {
                self?.sessions[game.id]?.status = Task.isCancelled ? .stopped : .failed(Self.describe(error))
            }
            self?.refreshRunningBottles()
        }
    }

    /// Runs a short-lived program in the game's bottle without tracking it, like `steam.exe` handing a
    /// link to the Steam already running there.
    private func forward(_ game: Game) {
        guard let bottle = bottle(for: game) else { return }
        let paths = self.paths
        Task { [weak self] in
            do {
                guard let engine = try RuntimeStore(paths: paths).engine(id: bottle.engineID) else {
                    throw AppError("No Wine runtime is installed. Add one under Setup.")
                }
                let prepared = try await Launcher.prepare(gameID: game.id, executable: game.executable, profile: game.profile,
                                                          bottle: bottle, engine: engine, paths: paths)
                _ = try await Launcher.run(prepared)
            } catch {
                self?.errorMessage = Self.describe(error)
            }
        }
    }

    /// Stops the launch and everything else running in its bottle (Wine can't stop just one game's processes).
    func stop(_ game: Game) {
        if let task = sessions[game.id]?.task, sessions[game.id]?.isActive == true {
            task.cancel()
        } else if let bottle = bottle(for: game) {
            stop(bottle)
        }
    }

    func stop(_ bottle: Bottle) {
        let paths = self.paths
        Task {
            await perform("Stopping \(bottle.name)…") {
                guard let engine = try RuntimeStore(paths: paths).engine(id: bottle.engineID) else { return }
                try Launcher.stop(bottle, engine: engine, paths: paths)
            }
            for (id, session) in sessions where session.isActive && session.game.bottleID == bottle.id {
                sessions[id]?.task?.cancel()
            }
        }
    }

    /// Built from `tools/steamwebhelper-wrapper` into the app's resources (see project.yml).
    private static let steamWebHelperWrapper = Bundle.main.url(forResource: "steamwebhelper-wrapper", withExtension: "exe")

    private static func startOverlay(prefix: URL) {
        guard let tool = Bundle.main.url(forAuxiliaryExecutable: "perf-overlay") else { return }
        let overlay = Process()
        overlay.executableURL = tool
        overlay.arguments = [prefix.path]
        try? overlay.run()
    }

    // MARK: Bottles

    func createBottle(name: String, kind: Bottle.Kind, allowNetwork: Bool = false) {
        let paths = self.paths
        Task {
            await perform("Creating the bottle \"\(name)\"… (Wine sets up Windows; this takes a minute)") {
                guard let engine = try RuntimeStore(paths: paths).engine() else {
                    throw AppError("Add a Wine runtime first.")
                }
                let bottle = Bottle(name: name, kind: kind, engineID: engine.id, isolation: IsolationPolicy(allowNetwork: allowNetwork))
                try await BottleStore(paths: paths).create(bottle, engine: engine)
            }
        }
    }

    func importBottle(from folder: URL) {
        let paths = self.paths
        Task {
            await perform("Adding the bottle from \(folder.lastPathComponent)…") {
                try BottleStore(paths: paths).importBottle(from: folder)
            }
        }
    }

    func resetToClean(_ bottle: Bottle) {
        let paths = self.paths
        Task {
            await perform("Resetting \(bottle.name) to its clean state…") {
                guard let engine = try RuntimeStore(paths: paths).engine(id: bottle.engineID) else { return }
                try BottleStore(paths: paths).resetToClean(bottle, engine: engine)
            }
        }
    }

    func driveC(of bottle: Bottle) -> URL {
        BottleLocation(bottleID: bottle.id, paths: paths).prefix.appending(path: "drive_c", directoryHint: .isDirectory)
    }

    // MARK: Runtimes and components

    func installRuntime(folder: URL) {
        let paths = self.paths
        Task {
            await perform("Adding the Wine runtime from \(folder.lastPathComponent)…") {
                try RuntimeStore(paths: paths).install(directory: folder)
            }
        }
    }

    func installRuntime(archive: URL, sha256: String) {
        let paths = self.paths
        Task {
            await perform("Checking and unpacking \(archive.lastPathComponent)…") {
                try RuntimeStore(paths: paths).install(archive: archive, sha256: sha256.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    func importComponents(from folder: URL) {
        let paths = self.paths
        Task {
            let added = await perform("Adding graphics components from \(folder.lastPathComponent)…") {
                try ComponentCatalog.importComponents(from: folder, into: paths.components)
            }
            if added?.isEmpty == true { errorMessage = "No new components in \(folder.path) (looked for dxmt-*, dxvk-macos-*, d3dmetal-*)." }
        }
    }

    func importGPTK(dmg: URL) {
        let paths = self.paths
        Task {
            await perform("Importing D3DMetal from \(dmg.lastPathComponent)…") {
                try GPTKImporter.importToolkit(dmg: dmg, into: paths.components)
            }
        }
    }

    // MARK: Helpers

    /// Runs slow work off the main thread with a status line; errors become an alert. Reloads afterwards.
    @discardableResult
    private func perform<T: Sendable>(_ title: String, _ work: @escaping @Sendable () async throws -> T) async -> T? {
        activity = title
        defer {
            activity = nil
            reload()
        }
        do {
            return try await Task.detached(priority: .userInitiated) { try await work() }.value
        } catch {
            errorMessage = Self.describe(error)
            return nil
        }
    }

    static func describe(_ error: Error) -> String {
        // Foundation's errors have good localized text; GameCore's describe themselves (their bridged
        // localizedDescription is just "error 3").
        if type(of: error) is NSError.Type || error is CocoaError || error is POSIXError || error is URLError {
            return error.localizedDescription
        }
        return String(describing: error)
    }
}

struct AppError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
