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
    ]

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
    public static func libraryEntries(for bottle: Bottle, prefix: URL, excluding known: Set<String> = []) -> [Game] {
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
        return games.filter { !known.contains($0.storeKey!) }
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
        let fm = FileManager.default
        let cef = steamRoot.appending(path: "bin/cef/cef.win64", directoryHint: .isDirectory)
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
