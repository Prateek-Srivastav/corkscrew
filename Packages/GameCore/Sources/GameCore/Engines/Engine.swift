import Foundation

public enum CPUArchitecture: String, Codable, Sendable {
    /// x86-64 Wine translated by Rosetta 2. Works through macOS 27.
    case x86_64
    /// Native ARM64 Wine with FEX translating x86 code. Needed once macOS 28 restricts Rosetta.
    case arm64
}

/// An installed Wine runtime (winecx under Rosetta today, ARM64 + FEX later).
///
/// Data-driven, so adding an engine means adding a manifest entry, not code.
public struct Engine: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var root: URL
    public var architecture: CPUArchitecture
    /// Builtin-DLL folders per backend (each with `x86_64-windows/`, `i386-windows/`, `x86_64-unix/`),
    /// searched in order through `WINEDLLPATH`. Wine checks its own `lib/wine` first, so the runtime is
    /// built without its Direct3D DLLs; these folders alone decide what a game gets, and nothing is
    /// copied into the bottle.
    public var backendDLLPaths: [GraphicsBackend: [URL]]
    /// Extra environment per backend, e.g. `CX_APPLEGPTK_LIBD3DSHARED_PATH` for D3DMetal.
    public var backendEnvironment: [GraphicsBackend: [String: String]]
    /// WINEDLLOVERRIDES entries per backend, for special cases only. Backends don't need overrides:
    /// with the default load order a DLL shipped next to the game (e.g. ReShade) still wins.
    public var backendDLLOverrides: [GraphicsBackend: [String: String]]
    /// Folders this engine reads from (runtime plus graphics components); isolated bottles may read
    /// these and nothing else outside the bottle.
    public var readOnlyRoots: [URL]

    public init(
        id: String,
        root: URL,
        architecture: CPUArchitecture,
        backendDLLPaths: [GraphicsBackend: [URL]] = [:],
        backendEnvironment: [GraphicsBackend: [String: String]] = [:],
        backendDLLOverrides: [GraphicsBackend: [String: String]] = [:],
        readOnlyRoots: [URL]? = nil
    ) {
        self.id = id
        self.root = root
        self.architecture = architecture
        self.backendDLLPaths = backendDLLPaths
        self.backendEnvironment = backendEnvironment
        self.backendDLLOverrides = backendDLLOverrides
        self.readOnlyRoots = readOnlyRoots ?? [root]
    }

    public var wine: URL { root.appending(path: "bin/wine") }
    public var wineserver: URL { root.appending(path: "bin/wineserver") }
    /// Wine's own Direct3D DLLs, moved out of `lib/wine` at build time. Every backend falls back to
    /// them for the DLLs it doesn't provide (e.g. DXVK-macOS has no dxgi, DXMT has no d3d12).
    public var wined3dDLLs: URL { root.appending(path: "lib/wine-backends/wined3d", directoryHint: .isDirectory) }
}

extension GraphicsBackend: CodingKeyRepresentable {}
