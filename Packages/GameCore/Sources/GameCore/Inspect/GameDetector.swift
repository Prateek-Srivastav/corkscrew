import Foundation

public enum GameEngine: String, Codable, Sendable {
    /// Unreal Engine 4/5. Unreal Engine 3 games are `unreal3`: older, often 32-bit and DX9 first.
    case unreal, unreal3, unity, godot
}

/// Anti-cheat software found next to a game. Kernel-level anti-cheat can't run under Wine on macOS.
public struct AntiCheatFinding: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case easyAntiCheat, battlEye, punkBuster, vanguard, eaAntiCheat, xigncode, nProtect, mhyprot
    }

    public enum Severity: String, Codable, Sendable {
        /// Kernel driver with no Wine support: the game won't start or will refuse online play.
        case blocksLaunch
        /// Works only if the developer enabled Wine/Proton support; online modes often fail.
        case mayBlockOnline
    }

    public let kind: Kind
    /// Path, relative to the game folder, of the file that matched.
    public let evidence: String

    public var severity: Severity {
        switch kind {
        case .easyAntiCheat, .battlEye, .punkBuster: .mayBlockOnline
        case .vanguard, .eaAntiCheat, .xigncode, .nProtect, .mhyprot: .blocksLaunch
        }
    }
}

public struct GameInspection: Sendable, Equatable {
    /// The executable the user picked; this is what gets launched.
    public let executable: URL
    /// The binary actually inspected (e.g. an Unreal `*-Shipping.exe` behind a launcher stub).
    public let inspectedBinary: URL
    public let machine: PEFile.Machine
    public let isDotNet: Bool
    public let graphicsAPIs: Set<GraphicsAPI>
    public let engine: GameEngine?
    public let antiCheat: [AntiCheatFinding]

    public var recommendedBackend: GraphicsBackend { .recommended(for: graphicsAPIs, machine: machine) }
}

/// Works out what a Windows game needs before its first launch.
public enum GameDetector {
    public static func inspect(executable: URL) throws -> GameInspection {
        let fm = FileManager.default
        let binary = unrealShippingBinary(near: executable) ?? executable
        let pe = try PEFile(contentsOf: binary)

        var apis = Set(pe.allImports.compactMap(GraphicsAPI.init(dllName:)))
        // Engines usually load their renderer at runtime (Unity's UnityPlayer.dll, Unreal's RHI
        // modules), so check the game's own DLLs too: their imports, and DLL names they only pass to
        // LoadLibrary, which leave just a string behind.
        let binaryDir = binary.deletingLastPathComponent()
        let siblings = (try? fm.contentsOfDirectory(at: binaryDir, includingPropertiesForKeys: nil)) ?? []
        let modules = [binary] + siblings.filter { $0.pathExtension.lowercased() == "dll" }.prefix(200)
        for module in modules.dropFirst() {
            guard let dll = try? PEFile(contentsOf: module) else { continue }
            apis.formUnion(dll.allImports.compactMap(GraphicsAPI.init(dllName:)))
        }
        // Each module is read once, for every API not found yet; this runs before every launch.
        let loadedAtRuntime: [(GraphicsAPI, String)] = [(.d3d12, "d3d12.dll"), (.d3d11, "d3d11.dll"), (.d3d9, "d3d9.dll")]
        for module in modules {
            let missing = loadedAtRuntime.filter { !apis.contains($0.0) }
            if missing.isEmpty { break }
            let found = mentions(of: missing.map(\.1), in: module)
            apis.formUnion(missing.filter { found.contains($0.1) }.map(\.0))
        }

        let root = gameRoot(for: executable)
        return GameInspection(
            executable: executable,
            inspectedBinary: binary,
            machine: pe.machine,
            isDotNet: pe.isDotNet,
            graphicsAPIs: apis,
            engine: detectEngine(executable: executable, root: root, binary: binary),
            antiCheat: scanAntiCheat(root: root)
        )
    }

    /// Unreal games ship `Game.exe` (a stub) next to `Game/Binaries/Win64/Game-Win64-Shipping.exe`.
    static func unrealShippingBinary(near executable: URL) -> URL? {
        let fm = FileManager.default
        let root = executable.deletingLastPathComponent()
        let stem = executable.deletingPathExtension().lastPathComponent.lowercased()
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        var candidates: [URL] = []
        for project in projects {
            let win64 = project.appending(path: "Binaries/Win64")
            guard let files = try? fm.contentsOfDirectory(at: win64, includingPropertiesForKeys: nil) else { continue }
            candidates += files.filter { $0.lastPathComponent.lowercased().hasSuffix("-shipping.exe") }
        }
        // Sorted: the directory's own order isn't stable, and the pick decides the backend.
        candidates.sort { $0.path < $1.path }
        return candidates.first { $0.lastPathComponent.lowercased().hasPrefix(stem) } ?? candidates.first
    }

    /// The folder to scan for anti-cheat and engine markers. Unreal 4/5 keep binaries in
    /// `<root>/<Project>/Binaries/Win64`; Unreal 3 keeps them in `<root>/Binaries/Win32|Win64`.
    static func gameRoot(for executable: URL) -> URL {
        let dir = executable.deletingLastPathComponent()
        let components = dir.pathComponents.map { $0.lowercased() }
        guard components.dropLast().last == "binaries", let arch = components.last, ["win32", "win64"].contains(arch)
        else { return dir }
        let binariesParent = dir.deletingLastPathComponent().deletingLastPathComponent()
        if isUnreal3Root(binariesParent) { return binariesParent }
        return arch == "win64" ? binariesParent.deletingLastPathComponent() : dir
    }

    /// Unreal 3 games have `Binaries/` and `Engine/` at the root, and a game folder with cooked
    /// content (`UDKGame/CookedPCConsole`, `TribesGame/CookedPC`, …); Unreal 4/5 have `Engine/Binaries`.
    static func isUnreal3Root(_ root: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appending(path: "Binaries").path),
              fm.fileExists(atPath: root.appending(path: "Engine").path),
              !fm.fileExists(atPath: root.appending(path: "Engine/Binaries").path),
              let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return false }
        return folders.prefix(100).contains { folder in
            let contents = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            return contents.contains { $0.lowercased().hasPrefix("cookedpc") }
        }
    }

    static func detectEngine(executable: URL, root: URL, binary: URL) -> GameEngine? {
        let fm = FileManager.default
        let dir = executable.deletingLastPathComponent()
        let stem = executable.deletingPathExtension().lastPathComponent
        if binary.lastPathComponent.lowercased().hasSuffix("-shipping.exe")
            || fm.fileExists(atPath: root.appending(path: "Engine/Binaries").path) {
            return .unreal
        }
        if isUnreal3Root(root) { return .unreal3 }
        if fm.fileExists(atPath: dir.appending(path: "UnityPlayer.dll").path)
            || fm.fileExists(atPath: dir.appending(path: "\(stem)_Data").path) {
            return .unity
        }
        if fm.fileExists(atPath: dir.appending(path: "\(stem).pck").path) { return .godot }
        return nil
    }

    private static let antiCheatMarkers: [String: AntiCheatFinding.Kind] = [
        "easyanticheat": .easyAntiCheat,
        "easyanticheat_eos": .easyAntiCheat,
        "easyanticheat_x64.dll": .easyAntiCheat,
        "start_protected_game.exe": .easyAntiCheat,
        "battleye": .battlEye,
        "beservice_x64.exe": .battlEye,
        "beclient_x64.dll": .battlEye,
        "pnkbstra.exe": .punkBuster,
        "pnkbstrb.exe": .punkBuster,
        "vgk.sys": .vanguard,
        "vgc.exe": .vanguard,
        "eaanticheat.gameservicelauncher.exe": .eaAntiCheat,
        "eaanticheat.installer.exe": .eaAntiCheat,
        "x3.xem": .xigncode,
        "xigncode": .xigncode,
        "gameguard": .nProtect,
        "gamemon.des": .nProtect,
        "mhyprot2.sys": .mhyprot,
        "mhyprot3.sys": .mhyprot,
    ]

    /// Walks the game folder (depth ≤ 3, ≤ 5000 entries) looking for anti-cheat files and folders.
    static func scanAntiCheat(root: URL) -> [AntiCheatFinding] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var findings: [AntiCheatFinding] = []
        var seen = Set<AntiCheatFinding.Kind>()
        var visited = 0
        let rootDepth = root.standardizedFileURL.pathComponents.count
        while let url = walker.nextObject() as? URL, visited < 5000 {
            visited += 1
            if url.standardizedFileURL.pathComponents.count - rootDepth >= 3 { walker.skipDescendants() }
            guard let kind = antiCheatMarkers[url.lastPathComponent.lowercased()], !seen.contains(kind) else { continue }
            seen.insert(kind)
            let relative = url.standardizedFileURL.pathComponents.dropFirst(rootDepth).joined(separator: "/")
            findings.append(AntiCheatFinding(kind: kind, evidence: relative))
        }
        return findings
    }

    /// Case-insensitive check for a DLL name stored as ASCII or UTF-16LE inside a binary.
    static func binaryMentions(_ binary: URL, dll: String) -> Bool {
        mentions(of: [dll], in: binary).contains(dll)
    }

    /// The DLL names in `dlls` that `binary` mentions (as ASCII or UTF-16LE, in common casings),
    /// reading the file once.
    static func mentions(of dlls: [String], in binary: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: binary, options: .alwaysMapped) else { return [] }
        return data.withUnsafeBytes { haystack in
            guard let base = haystack.baseAddress else { return [] }
            return Set(dlls.filter { dll in
                let spellings = Set([dll.lowercased(), dll.uppercased(), dll.prefix(dll.count - 4).uppercased() + ".dll"])
                return spellings.contains { spelling in
                    let ascii = Array(spelling.utf8)
                    return [ascii, ascii.flatMap { [$0, 0] }].contains { needle in
                        needle.withUnsafeBytes { memmem(base, haystack.count, $0.baseAddress, $0.count) != nil }
                    }
                }
            })
        }
    }
}
