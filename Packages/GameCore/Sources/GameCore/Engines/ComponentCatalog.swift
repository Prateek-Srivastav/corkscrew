import Foundation

/// Finds the graphics backends staged in a components folder and wires them into an engine.
///
/// Layout (see scripts/install-components.sh):
/// - `dxmt-<version>/`, `dxvk-macos-<version>/`: Wine DLL folders (`x86_64-windows/`, `i386-windows/`, `x86_64-unix/`)
/// - `d3dmetal-<version>/{external,wine}`: Apple's GPTK `redist/lib`, from the engine pack or a toolkit download
///
/// The newest stable version of each component wins unless `d3dmetalVersion` picks a staged toolkit (e.g. "4.0b2").
/// Betas are only the default when nothing stable is staged: GPTK 4.0 beta 2 renders Wukong as blocks.
public enum ComponentCatalog {
    public enum Error: Swift.Error, CustomStringConvertible {
        case notStaged(String)
        public var description: String {
            switch self { case .notStaged(let folder): "\(folder) isn't staged; run scripts/install-components.sh with that toolkit" }
        }
    }

    public static func engine(id: String, root: URL, architecture: CPUArchitecture, components: URL,
                              d3dmetalVersion: String? = nil) throws -> Engine {
        var engine = Engine(id: id, root: root, architecture: architecture, readOnlyRoots: [root, components])
        if let dxmt = newest("dxmt-", in: components) {
            engine.backendDLLPaths[.dxmt] = [dxmt]
        }
        if let dxvk = newest("dxvk-macos-", in: components) {
            engine.backendDLLPaths[.dxvk] = [dxvk]
        }
        var gptk = newest("d3dmetal-", in: components)
        if let version = d3dmetalVersion {
            let folder = components.appending(path: "d3dmetal-\(version)", directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: folder.path) else { throw Error.notStaged(folder.lastPathComponent) }
            gptk = folder
        }
        if let gptk {
            engine.backendDLLPaths[.d3dmetal] = [gptk.appending(path: "wine", directoryHint: .isDirectory)]
            // winecx's ntdll loads this to register Windows code regions with D3DMetal.
            engine.backendEnvironment[.d3dmetal] = [
                "CX_APPLEGPTK_LIBD3DSHARED_PATH": gptk.appending(path: "external/libd3dshared.dylib").path,
            ]
        }
        return engine
    }

    /// Folder-name prefixes of the components the catalog knows.
    static let componentPrefixes = ["dxmt-", "dxvk-macos-", "d3dmetal-"]

    /// Copies staged components (`scripts/install-components.sh` output, e.g. `build/components`) into
    /// `components` as APFS clones; ones already there are kept unless `replacing` (a newer engine
    /// pack's copy of the same version). Returns the folder names added.
    @discardableResult
    public static func importComponents(from source: URL, into components: URL, replacing: Bool = false) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: components, withIntermediateDirectories: true)
        let folders = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        var added: [String] = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where folder.hasDirectoryPath && componentPrefixes.contains(where: folder.lastPathComponent.hasPrefix) {
            let destination = components.appending(path: folder.lastPathComponent, directoryHint: .isDirectory)
            if fm.fileExists(atPath: destination.path) {
                guard replacing else { continue }
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: folder, to: destination)  // clonefile on APFS; keeps symlinks
            added.append(folder.lastPathComponent)
        }
        return added
    }

    /// Staged component folders in `components`, by name.
    public static func staged(in components: URL) -> [String] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: components, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return folders.map(\.lastPathComponent).filter { name in componentPrefixes.contains(where: name.hasPrefix) }.sorted()
    }

    /// Backends with a staged component; WineD3D ships inside the runtime and is always available.
    public static func availableBackends(of engine: Engine) -> Set<GraphicsBackend> {
        Set(engine.backendDLLPaths.keys).union([.wined3d])
    }

    /// The folder with the highest version for a prefix, comparing versions numerically (0.80 > 0.9).
    /// Pre-releases ("4.0b2", "1.2rc1") lose to any stable release.
    static func newest(_ prefix: String, in components: URL) -> URL? {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: components, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        )) ?? []
        return folders
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.hasDirectoryPath }
            .max { a, b in
                let (va, vb) = (a.lastPathComponent.dropFirst(prefix.count), b.lastPathComponent.dropFirst(prefix.count))
                if isPrerelease(va) != isPrerelease(vb) { return isPrerelease(va) }
                return version(va).lexicographicallyPrecedes(version(vb))
            }
    }

    private static func isPrerelease(_ text: Substring) -> Bool {
        text.contains(/\d(a|b|beta|rc)\d*$/)
    }

    private static func version(_ text: Substring) -> [Int] {
        text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}
