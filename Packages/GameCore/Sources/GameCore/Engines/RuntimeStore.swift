import CryptoKit
import Foundation

/// What `scripts/build-runtime.sh` writes to `<runtime>/manifest.json`.
public struct RuntimeManifest: Codable, Sendable, Equatable {
    public var id: String
    public var architecture: CPUArchitecture
    /// The Wine source tarball the runtime was built from, and its pinned SHA-256.
    public var source: String
    public var sourceSHA256: String
    public var moltenVK: String?
    public var builtAt: String?
}

/// Installs and lists Wine runtimes under `AppPaths.runtimes/<id>/`.
public struct RuntimeStore: Sendable {
    public enum StoreError: Error, Equatable, CustomStringConvertible {
        case checksumMismatch(expected: String, actual: String)
        case extractFailed(status: Int32)
        case notARuntime(String)
        case alreadyInstalled(String)

        public var description: String {
            switch self {
            case .checksumMismatch(let expected, let actual): "checksum mismatch: expected \(expected), got \(actual)"
            case .extractFailed(let status): "couldn't unpack the runtime archive (tar exited \(status))"
            case .notARuntime(let path): "\(path) has no manifest.json and bin/wine, so it isn't a runtime"
            case .alreadyInstalled(let id): "runtime \(id) is already installed"
            }
        }
    }

    public let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    public func location(of id: String) -> URL { paths.runtimes.appending(path: id, directoryHint: .isDirectory) }

    /// Installed runtimes, by id.
    public func list() -> [RuntimeManifest] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: paths.runtimes, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { try? Self.manifest(in: $0) }.sorted { $0.id < $1.id }
    }

    /// The engine for an installed runtime, with the graphics components staged in `AppPaths.components`.
    /// Uses runtime `id` when it's installed (a bottle's `engineID`), otherwise the newest installed one;
    /// nil when no runtime is installed.
    public func engine(id: String? = nil, d3dmetalVersion: String? = nil) throws -> Engine? {
        let installed = list()
        guard let manifest = installed.first(where: { $0.id == id }) ?? installed.last else { return nil }
        return try ComponentCatalog.engine(id: manifest.id, root: location(of: manifest.id), architecture: manifest.architecture,
                                           components: paths.components, d3dmetalVersion: d3dmetalVersion)
    }

    /// Unpacks a runtime archive (`.tar.xz`, `.tar.gz`, …) after checking it against `sha256`. The
    /// archive holds one runtime folder (`bin/`, `lib/`, `manifest.json`), at the top or one level down.
    @discardableResult
    public func install(archive: URL, sha256 expected: String) throws -> RuntimeManifest {
        let actual = try Self.sha256(of: archive)
        guard actual == expected.lowercased() else { throw StoreError.checksumMismatch(expected: expected.lowercased(), actual: actual) }

        let staging = try stagingFolder()
        defer { try? FileManager.default.removeItem(at: staging) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xf", archive.path, "-C", staging.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw StoreError.extractFailed(status: tar.terminationStatus) }

        let contents = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        let root = contents.count == 1 && (try? Self.manifest(in: contents[0])) != nil ? contents[0] : staging
        return try moveIntoPlace(root)
    }

    /// Installs a runtime folder built on this Mac (`build/runtime/winecx-*`) as an APFS clone:
    /// instant, and no extra disk space until either copy changes.
    @discardableResult
    public func install(directory: URL) throws -> RuntimeManifest {
        _ = try Self.manifest(in: directory)
        let staging = try stagingFolder()
        defer { try? FileManager.default.removeItem(at: staging) }
        let copy = staging.appending(path: "runtime", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: directory, to: copy)  // clonefile on APFS
        return try moveIntoPlace(copy)
    }

    /// Reads and validates a runtime folder's manifest.
    public static func manifest(in folder: URL) throws -> RuntimeManifest {
        let fm = FileManager.default
        let manifest = folder.appending(path: "manifest.json")
        guard fm.fileExists(atPath: manifest.path), fm.isExecutableFile(atPath: folder.appending(path: "bin/wine").path)
        else { throw StoreError.notARuntime(folder.path) }
        return try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: manifest))
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A scratch folder on the same volume as the runtimes, so the final move is a rename.
    private func stagingFolder() throws -> URL {
        let staging = paths.runtimes.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    private func moveIntoPlace(_ root: URL) throws -> RuntimeManifest {
        let manifest = try Self.manifest(in: root)
        let destination = location(of: manifest.id)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw StoreError.alreadyInstalled(manifest.id) }
        try FileManager.default.moveItem(at: root, to: destination)
        return manifest
    }
}

/// Which Windows modules a runtime provides.
///
/// Wine only loads a builtin module that has a placeholder in the bottle's `system32`, and
/// `wineboot -u` creates them. Bottles remember the fingerprint they were last booted with, so a
/// runtime that gains modules (a rebuild, DXMT's `winemetal`) updates them before the next launch.
public enum RuntimeModules {
    /// Hash of the module names in `lib/wine/{x86_64,i386}-windows`. Names, not contents: a changed
    /// module still has its placeholder, and Wine loads builtins from the runtime anyway.
    public static func fingerprint(runtime root: URL) -> String {
        let fm = FileManager.default
        var names: [String] = []
        for arch in ["x86_64-windows", "i386-windows"] {
            let folder = root.appending(path: "lib/wine/\(arch)", directoryHint: .isDirectory)
            let files = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            names += files.map { "\(arch)/\($0.lowercased())" }
        }
        let digest = SHA256.hash(data: Data(names.sorted().joined(separator: "\n").utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
