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

        public var description: String {
            switch self {
            case .missingRuntime: "the engine pack has no runtime/ folder with a Wine runtime in it"
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

    /// Checks `archive` against `sha256`, then installs its runtime and adds its components. A
    /// runtime or component that's already installed is kept. Returns the runtime's manifest.
    @discardableResult
    public static func install(archive: URL, sha256 expected: String, paths: AppPaths) throws -> RuntimeManifest {
        let actual = try RuntimeStore.sha256(of: archive)
        guard actual == expected.lowercased() else {
            throw RuntimeStore.StoreError.checksumMismatch(expected: expected.lowercased(), actual: actual)
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
        if !fm.fileExists(atPath: store.location(of: manifest.id).path) {
            _ = try store.moveIntoPlace(runtime)
        }
        let components = root.appending(path: "components", directoryHint: .isDirectory)
        if fm.fileExists(atPath: components.path) {
            try ComponentCatalog.importComponents(from: components, into: paths.components)
        }
        return manifest
    }
}
