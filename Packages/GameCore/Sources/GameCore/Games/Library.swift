import Foundation

/// A Windows program in the library: what to run, in which bottle, with which settings.
public struct Game: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var executable: URL
    public var bottleID: UUID
    public var profile: GameProfile
    public var addedAt: Date
    public var lastPlayedAt: Date?
    /// Set for entries the app found in a store (Steam and its installed games).
    public var store: StoreItem?
    /// Where the icon comes from when it isn't `executable` (a Steam game launches `steam.exe`).
    public var iconSource: URL?

    public init(
        id: UUID = UUID(), name: String, executable: URL, bottleID: UUID, profile: GameProfile = GameProfile(),
        addedAt: Date = .now, lastPlayedAt: Date? = nil, store: StoreItem? = nil, iconSource: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.executable = executable
        self.bottleID = bottleID
        self.profile = profile
        self.addedAt = addedAt
        self.lastPlayedAt = lastPlayedAt
        self.store = store
        self.iconSource = iconSource
    }

    /// Identifies a store entry across launches: the same item in the same bottle.
    public var storeKey: String? { store?.key(in: bottleID) }

    /// A name for a newly added program: the game's folder for Unreal's `Binaries/Win64/*-Shipping.exe`,
    /// otherwise the file name without `.exe`.
    public static func defaultName(for executable: URL) -> String {
        let root = GameDetector.gameRoot(for: executable)
        if root != executable.deletingLastPathComponent() { return root.lastPathComponent }
        return executable.deletingPathExtension().lastPathComponent
    }
}

/// A launcher or game found in a store's own files, e.g. Steam's `appmanifest_<id>.acf`.
public struct StoreItem: Codable, Hashable, Sendable {
    public var store: String
    /// The store's id for the game; nil for the store's own client (Steam itself).
    public var appID: String?

    public init(store: String, appID: String? = nil) {
        self.store = store
        self.appID = appID
    }

    /// Identifies the item in one bottle across launches (`Game.storeKey`).
    public func key(in bottleID: UUID) -> String {
        "\(store):\(bottleID.uuidString):\(appID ?? "client")"
    }
}

/// The games in the library, plus the store entries the user removed (so they stay removed).
public struct Library: Codable, Equatable, Sendable {
    public var games: [Game]
    /// `Game.storeKey`s of found entries the user removed.
    public var removedStoreItems: Set<String>
    /// The `Steam.settingsVersion` the store entries were last brought up to.
    public var storeSettingsVersion: Int

    public init(games: [Game] = [], removedStoreItems: Set<String> = []) {
        self.games = games
        self.removedStoreItems = removedStoreItems
        storeSettingsVersion = Steam.settingsVersion
    }

    /// A library saved with older store settings is brought up to date as it loads; the next save
    /// records that, so later changes the user makes stay.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        games = try c.decodeIfPresent([Game].self, forKey: .games) ?? []
        removedStoreItems = try c.decodeIfPresent(Set<String>.self, forKey: .removedStoreItems) ?? []
        let version = try c.decodeIfPresent(Int.self, forKey: .storeSettingsVersion) ?? 1
        if version < Steam.settingsVersion { games = games.map { Steam.upgraded($0, from: version) } }
        storeSettingsVersion = max(version, Steam.settingsVersion)
    }

    /// Adds found store entries that aren't in the library and weren't removed. Returns the added ones.
    @discardableResult
    public mutating func addMissing(_ found: [Game]) -> [Game] {
        let known = Set(games.compactMap(\.storeKey)).union(removedStoreItems)
        let added = found.filter { $0.storeKey.map { !known.contains($0) } ?? false }
        games += added
        return added
    }

    public mutating func remove(_ id: Game.ID) {
        guard let game = games.first(where: { $0.id == id }) else { return }
        if let key = game.storeKey { removedStoreItems.insert(key) }
        games.removeAll { $0.id == id }
    }
}

/// Reads and writes the library (`library.json`) and caches game icons.
public struct LibraryStore: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    /// The saved library. A missing file is an empty library.
    public func load() throws -> Library {
        guard FileManager.default.fileExists(atPath: paths.library.path) else { return Library() }
        return try JSONDecoder.bottles.decode(Library.self, from: Data(contentsOf: paths.library))
    }

    public func save(_ library: Library) throws {
        try FileManager.default.createDirectory(at: paths.supportRoot, withIntermediateDirectories: true)
        try JSONEncoder.bottles.encode(library).write(to: paths.library, options: .atomic)
    }

    /// The game's icon as `.ico` data, extracted from its executable once and then cached.
    /// Nil when the program has no icon (or isn't there any more).
    public func icon(for game: Game) -> Data? {
        let cached = paths.icons.appending(path: "\(game.id.uuidString).ico")
        if let data = try? Data(contentsOf: cached) { return data }
        guard let data = try? PEFile.icon(contentsOf: game.iconSource ?? game.executable) else { return nil }
        try? FileManager.default.createDirectory(at: paths.icons, withIntermediateDirectories: true)
        try? data.write(to: cached, options: .atomic)
        return data
    }

    /// Forgets a removed game's cached icon. Its logs stay until the user deletes them.
    public func removeCachedIcon(for game: Game) {
        try? FileManager.default.removeItem(at: paths.icons.appending(path: "\(game.id.uuidString).ico"))
    }
}
