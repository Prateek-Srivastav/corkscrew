import Foundation

/// What a downloaded copy of Corkscrew installs on first launch instead of building anything: the
/// Wine runtime and the graphics components: D3DMetal (Apple's Game Porting Toolkit, whose license
/// allows non-commercial redistribution with Apple's notices), DXMT and DXVK.
///
/// `scripts/package-engine.sh` builds the archive from `build/runtime` and `build/components` and
/// writes `EnginePack.current` (EnginePackPin.swift). Layout, under one top folder:
///
///     runtime/<runtime id>/      bin/, lib/, share/, manifest.json
///     components/dxmt-*/, components/dxvk-macos-*/
///     LICENSES/, SOURCES.md
public struct EnginePack: Sendable, Equatable {
    public enum PackError: Error, Equatable, CustomStringConvertible {
        case missingRuntime
        case bottlesRunning([String])

        public var description: String {
            switch self {
            case .missingRuntime: "the engine pack has no runtime/ folder with a Wine runtime in it"
            case .bottlesRunning(let names):
                "Wine can't be updated while programs run in \(names.map { "\"\($0)\"" }.joined(separator: ", ")); quit them and try again"
            }
        }
    }

    /// The pack's release, e.g. "26.3.0-1": the Wine version, then the pack's own revision.
    public var version: String
    public var url: URL
    public var sha256: String
    /// The archive's size in bytes, to show before downloading.
    public var size: Int64

    public init(version: String, url: URL, sha256: String, size: Int64) {
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.size = size
    }

    /// Whether installing this pack would change what's installed: no runtime came from it, and one
    /// came from an older pack. False with no runtime at all (that's first setup, not an upgrade) and
    /// for runtimes added by hand (`RuntimeStore.localBuild`).
    public func upgradesInstalledRuntime(in paths: AppPaths) -> Bool {
        let store = RuntimeStore(paths: paths)
        let versions = store.list().map { store.packVersion(of: $0.id) }
        guard !versions.contains(version) else { return false }
        return versions.contains { installed in installed != RuntimeStore.localBuild && Self.isOlder(installed ?? "", than: version) }
    }

    /// Compares pack releases number by number: "26.3.0-10" is newer than "26.3.0-9". An empty
    /// release (a runtime from before releases were recorded) is older than any.
    static func isOlder(_ a: String, than b: String) -> Bool {
        func numbers(_ release: String) -> [Int] { release.split { !$0.isNumber }.compactMap { Int($0) } }
        return numbers(a).lexicographicallyPrecedes(numbers(b))
    }

    /// Bottles whose wineserver is up; replacing the runtime under them would break them.
    static func runningBottles(paths: AppPaths) -> [Bottle] {
        let store = BottleStore(paths: paths)
        return ((try? store.list()) ?? []).filter { WineServer.isRunning(prefix: store.location(of: $0).prefix, base: paths.wineServerDirectory) }
    }

    /// Checks `archive` against the pack's checksum, then installs its runtime and components and
    /// records the pack's release in the runtime. Returns the runtime's manifest.
    ///
    /// A runtime with the same id from an older pack (or one installed before releases were
    /// recorded) is replaced, with the pack's components: a pack revision fixes the build, not the
    /// Wine version, so the id stays. Bottles keep working (they name the runtime by id); one that
    /// is running stops the upgrade. Otherwise what's installed is kept.
    @discardableResult
    public func install(archive: URL, paths: AppPaths) throws -> RuntimeManifest {
        let actual = try RuntimeStore.sha256(of: archive)
        guard actual == sha256.lowercased() else {
            throw RuntimeStore.StoreError.checksumMismatch(expected: sha256.lowercased(), actual: actual)
        }
        let store = RuntimeStore(paths: paths)
        let staging = try store.stagingFolder()
        defer { try? FileManager.default.removeItem(at: staging) }
        try RuntimeStore.unpack(archive, into: staging)

        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        let root = top.count == 1 && top[0].hasDirectoryPath ? top[0] : staging
        let runtimes = (try? fm.contentsOfDirectory(at: root.appending(path: "runtime"), includingPropertiesForKeys: nil)) ?? []
        guard let runtime = runtimes.first(where: { (try? RuntimeStore.manifest(in: $0)) != nil }) else {
            throw PackError.missingRuntime
        }
        let manifest = try RuntimeStore.manifest(in: runtime)
        try RuntimeStore.recordPackVersion(version, in: runtime)
        let installed = fm.fileExists(atPath: store.location(of: manifest.id).path)
        let replacing = installed && {
            let current = store.packVersion(of: manifest.id)
            return current != RuntimeStore.localBuild && Self.isOlder(current ?? "", than: version)
        }()
        if replacing {
            let running = Self.runningBottles(paths: paths)
            guard running.isEmpty else { throw PackError.bottlesRunning(running.map(\.name)) }
            _ = try store.replace(with: runtime)
        } else if !installed {
            _ = try store.moveIntoPlace(runtime)
        }
        let components = root.appending(path: "components", directoryHint: .isDirectory)
        if fm.fileExists(atPath: components.path) {
            try ComponentCatalog.importComponents(from: components, into: paths.components, replacing: replacing)
        }
        return manifest
    }
}
