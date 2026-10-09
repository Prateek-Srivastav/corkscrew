import Foundation
import Testing
@testable import GameCore

struct GameDetectorTests {
    @Test func unityGameUsesSiblingDLLImports() throws {
        try withTempDir { root in
            let exe = root.appending(path: "Game/Game.exe")
            try exe.write(PEBuilder(imports: ["kernel32.dll"]).build())
            try root.appending(path: "Game/UnityPlayer.dll").write(PEBuilder(isDLL: true, imports: ["d3d11.dll", "dxgi.dll"]).build())
            try root.appending(path: "Game/Game_Data").makeDirectory()

            let result = try GameDetector.inspect(executable: exe)
            #expect(result.graphicsAPIs == [.d3d11])
            #expect(result.engine == .unity)
            #expect(result.recommendedBackend == .dxmt)
            #expect(result.antiCheat.isEmpty)
        }
    }

    @Test func unrealStubResolvesToShippingBinaryAndFindsRuntimeLoadedD3D12() throws {
        try withTempDir { root in
            let stub = root.appending(path: "MyGame.exe")
            try stub.write(PEBuilder(imports: ["kernel32.dll"]).build())
            let shipping = root.appending(path: "MyGame/Binaries/Win64/MyGame-Win64-Shipping.exe")
            // Unreal loads d3d12.dll at runtime, so it only appears as a UTF-16 string.
            try shipping.write(PEBuilder(imports: ["kernel32.dll", "dxgi.dll"], payload: utf16LE("D3D12.dll")).build())

            let result = try GameDetector.inspect(executable: stub)
            #expect(result.executable == stub)
            #expect(result.inspectedBinary.lastPathComponent == "MyGame-Win64-Shipping.exe")
            #expect(result.graphicsAPIs.contains(.d3d12))
            #expect(result.engine == .unreal)
            #expect(result.recommendedBackend == .d3dmetal)
        }
    }

    @Test func unreal3GameIsDetectedFromItsRootLayout() throws {
        try withTempDir { root in
            // Betrayer (GOG): Binaries/Win32/Betrayer.exe, Engine/Config, UDKGame/CookedPCConsole.
            let exe = root.appending(path: "Binaries/Win32/Betrayer.exe")
            try exe.write(PEBuilder(machine: 0x014C, pe32Plus: false, imports: ["d3d9.dll"]).build())
            try root.appending(path: "Engine/Config").makeDirectory()
            try root.appending(path: "UDKGame/CookedPCConsole").makeDirectory()
            try root.appending(path: "Binaries/EasyAntiCheat").makeDirectory()

            let result = try GameDetector.inspect(executable: exe)
            #expect(result.engine == .unreal3)
            #expect(result.machine == .i386)
            #expect(result.recommendedBackend == .wined3d)
            // Anti-cheat is looked for from the game root, not just next to the exe.
            #expect(result.antiCheat.map(\.kind) == [.easyAntiCheat])
        }
    }

    @Test func unreal4LayoutIsNotTakenForUnreal3() throws {
        try withTempDir { root in
            let exe = root.appending(path: "MyGame/Binaries/Win64/MyGame-Win64-Shipping.exe")
            try exe.write(PEBuilder(imports: ["d3d11.dll"]).build())
            try root.appending(path: "Engine/Binaries/ThirdParty").makeDirectory()
            try root.appending(path: "MyGame/Content/Paks").makeDirectory()

            #expect(GameDetector.gameRoot(for: exe).lastPathComponent == root.lastPathComponent)
            #expect(try GameDetector.inspect(executable: exe).engine == .unreal)
        }
    }

    @Test func unityThatLoadsDirect3DAtRuntimeIsNotMistakenForOpenGL() throws {
        try withTempDir { root in
            // Older 32-bit Unity: links OpenGL, loads d3d11.dll by name at runtime.
            let exe = root.appending(path: "Game/Game.exe")
            try exe.write(PEBuilder(machine: 0x014C, pe32Plus: false, imports: ["kernel32.dll"]).build())
            try root.appending(path: "Game/UnityPlayer.dll").write(PEBuilder(
                machine: 0x014C, pe32Plus: false, isDLL: true, imports: ["opengl32.dll"],
                payload: Array("d3d11.dll\0d3d12.dll\0".utf8)
            ).build())

            let result = try GameDetector.inspect(executable: exe)
            #expect(result.graphicsAPIs.isSuperset(of: [.d3d11, .d3d12, .opengl]))
            #expect(result.machine == .i386)
            // D3DMetal has no 32-bit build, so a 32-bit DX11/12 game gets DXMT.
            #expect(result.recommendedBackend == .dxmt)
        }
    }

    @Test func findsAntiCheatAndRatesSeverity() throws {
        try withTempDir { root in
            let exe = root.appending(path: "Game.exe")
            try exe.write(PEBuilder(imports: ["d3d11.dll"]).build())
            try root.appending(path: "EasyAntiCheat").makeDirectory()
            try root.appending(path: "drivers/vgk.sys").write("driver")

            let findings = try GameDetector.inspect(executable: exe).antiCheat
            let byKind = Dictionary(uniqueKeysWithValues: findings.map { ($0.kind, $0) })
            #expect(Set(byKind.keys) == [.easyAntiCheat, .vanguard])
            #expect(byKind[.easyAntiCheat]?.severity == .mayBlockOnline)
            #expect(byKind[.vanguard]?.severity == .blocksLaunch)
            #expect(byKind[.vanguard]?.evidence == "drivers/vgk.sys")
        }
    }

    @Test(arguments: [
        ([GraphicsAPI.d3d12, .d3d11], GraphicsBackend.d3dmetal),
        ([.d3d11], .dxmt),
        ([.d3d10], .dxmt),
        ([.d3d9], .wined3d),
        ([.vulkan], .wined3d),
        ([], .wined3d),
    ])
    func recommendedBackend(apis: [GraphicsAPI], expected: GraphicsBackend) {
        #expect(GraphicsBackend.recommended(for: Set(apis)) == expected)
    }

    @Test func thirtyTwoBitGamesNeverGetD3DMetal() {
        #expect(GraphicsBackend.recommended(for: [.d3d12, .d3d11], machine: .i386) == .dxmt)
        #expect(GraphicsBackend.recommended(for: [.d3d12], machine: .i386) == .wined3d)
        #expect(GraphicsBackend.recommended(for: [.d3d12], machine: .x86_64) == .d3dmetal)
    }

    @Test func mapsDLLNamesToAPIs() {
        #expect(GraphicsAPI(dllName: "d3d12.dll") == .d3d12)
        #expect(GraphicsAPI(dllName: "d3dx9_43.dll") == .d3d9)
        #expect(GraphicsAPI(dllName: "ddraw.dll") == .legacy)
        #expect(GraphicsAPI(dllName: "kernel32.dll") == nil)
    }
}
