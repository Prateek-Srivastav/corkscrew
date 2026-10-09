import Foundation

/// The graphics API a Windows game renders with, as detected from its binaries.
public enum GraphicsAPI: String, Codable, Sendable, CaseIterable, Comparable {
    /// DirectDraw / Direct3D 8 and older.
    case legacy
    case d3d9, d3d10, d3d11, d3d12, vulkan, opengl

    /// Maps an imported DLL name (lowercased) to the API it implies.
    public init?(dllName: String) {
        switch dllName {
        case "d3d12.dll": self = .d3d12
        case "d3d11.dll": self = .d3d11
        case "d3d10.dll", "d3d10_1.dll", "d3d10core.dll": self = .d3d10
        case "d3d9.dll": self = .d3d9
        case "d3d8.dll", "ddraw.dll": self = .legacy
        case "vulkan-1.dll": self = .vulkan
        case "opengl32.dll": self = .opengl
        default:
            if dllName.hasPrefix("d3dx11_") { self = .d3d11 }
            else if dllName.hasPrefix("d3dx10_") { self = .d3d10 }
            else if dllName.hasPrefix("d3dx9_") { self = .d3d9 }
            else { return nil }
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// How Direct3D calls are translated to Metal.
public enum GraphicsBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Apple's D3DMetal from the Game Porting Toolkit (D3D11/12). Comes with the engine pack.
    case d3dmetal
    /// Open-source D3D10/11 → Metal.
    case dxmt
    /// D3D9/10/11 → Vulkan, on MoltenVK.
    case dxvk
    /// Wine's built-in Direct3D (OpenGL). Also the right choice for Vulkan and OpenGL games.
    case wined3d

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .d3dmetal: "D3DMetal"
        case .dxmt: "DXMT"
        case .dxvk: "DXVK (MoltenVK)"
        case .wined3d: "WineD3D (built-in)"
        }
    }

    /// Auto mode. DX12 needs D3DMetal, which also handles the DX11 path of games that ship both, but
    /// D3DMetal is 64-bit only: 32-bit games get DXMT for DX10/11 and WineD3D otherwise.
    /// Only backends in `available` are picked: without D3DMetal, DX12 falls back to the game's DX11
    /// path or WineD3D (vkd3d); without DXMT, DX10/11 goes to DXVK.
    public static func recommended(
        for apis: Set<GraphicsAPI>, machine: PEFile.Machine = .x86_64, available: Set<GraphicsBackend> = Set(allCases)
    ) -> GraphicsBackend {
        let is64Bit = machine == .x86_64 || machine == .arm64
        if apis.contains(.d3d12), is64Bit, available.contains(.d3dmetal) { return .d3dmetal }
        if apis.contains(.d3d11) || apis.contains(.d3d10) {
            if available.contains(.dxmt) { return .dxmt }
            if available.contains(.dxvk) { return .dxvk }
        }
        return .wined3d
    }
}
