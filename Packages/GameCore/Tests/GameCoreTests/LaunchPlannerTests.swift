import Foundation
import Testing
@testable import GameCore

struct LaunchPlannerTests {
    private let host = [
        "HOME": "/Users/someone",
        "LANG": "en_US.UTF-8",
        "SSH_AUTH_SOCK": "/private/tmp/agent.sock",
        "GITHUB_TOKEN": "ghp_not_for_games",
    ]

    private struct Fixture {
        let paths: AppPaths
        let engine: Engine
        let location: BottleLocation
        let exe: URL

        func context(_ kind: Bottle.Kind, isolation: IsolationPolicy = IsolationPolicy(), engine: Engine? = nil, host: [String: String]) -> WineContext {
            let bottle = Bottle(name: "Games", kind: kind, engineID: self.engine.id, isolation: isolation)
            return WineContext(engine: engine ?? self.engine, bottle: bottle, location: location, paths: paths, hostEnvironment: host)
        }
    }

    private func fixture(_ root: URL) throws -> Fixture {
        let paths = AppPaths(
            supportRoot: root.appending(path: "support", directoryHint: .isDirectory),
            logsRoot: root.appending(path: "logs", directoryHint: .isDirectory),
            cachesRoot: root.appending(path: "caches", directoryHint: .isDirectory),
            userHome: root.appending(path: "home", directoryHint: .isDirectory),
            wineServerDirectory: root.appending(path: "wine-base", directoryHint: .isDirectory)
        )
        let engine = Engine(
            id: "winecx-test",
            root: paths.runtimes.appending(path: "winecx-test"),
            architecture: .x86_64,
            backendDLLPaths: [.dxmt: [paths.components.appending(path: "dxmt-0.80")]]
        )
        let location = BottleLocation(bottleID: UUID(), paths: paths)
        let exe = location.prefix.appending(path: "drive_c/Games/Demo/Demo.exe")
        try exe.write(PEBuilder().build())
        return Fixture(paths: paths, engine: engine, location: location, exe: exe)
    }

    @Test func standardBottleRunsWineDirectly() throws {
        try withTempDir { root in
            let f = try fixture(root)
            let game = GameLaunch(gameID: UUID(), executable: f.exe, profile: GameProfile(arguments: ["-windowed"]), detectedAPIs: [.d3d11])
            let plan = try LaunchPlanner.plan(game, in: f.context(.standard, host: host))

            #expect(plan.executable == f.engine.wine)
            #expect(plan.arguments == [f.exe.path, "-windowed"])
            #expect(plan.workingDirectory == f.exe.deletingLastPathComponent())
            #expect(plan.backend == .dxmt)
            #expect(plan.sandboxProfile == nil)
            #expect(plan.environment["WINEPREFIX"] == f.location.prefix.path)
            #expect(plan.environment["WINEMSYNC"] == "1")
            #expect(plan.environment["WINEDEBUG"] == "-all")
            #expect(plan.environment["ROSETTA_ADVERTISE_AVX"] == "1")
            // The backend is chosen by DLL search path, with Wine's own Direct3D as the fallback.
            #expect(plan.environment["WINEDLLPATH"] == "\(f.paths.components.appending(path: "dxmt-0.80").path):\(f.engine.wined3dDLLs.path)")
            #expect(plan.environment["CX_ACTIVE_GRAPHICS_BACKEND"] == "dxmt")
            #expect(plan.environment["WINEDLLOVERRIDES"] == "winemenubuilder.exe=")
            #expect(plan.environment["HOME"] == "/Users/someone")
            #expect(plan.environment["LANG"] == "en_US.UTF-8")
            #expect(plan.environment["SSH_AUTH_SOCK"] == nil)
            #expect(plan.environment["GITHUB_TOKEN"] == nil)
            #expect(plan.environment["MTL_HUD_ENABLED"] == nil)
            #expect(plan.environment["CORKSCREW_NO_LOADER_LINK"] == nil, "standard bottles keep per-game Dock names")
        }
    }

    @Test func installerPackagesRunThroughMsiexec() throws {
        try withTempDir { root in
            let f = try fixture(root)
            let msi = f.exe.deletingLastPathComponent().appending(path: "Setup.MSI")
            let plan = try LaunchPlanner.plan(GameLaunch(gameID: UUID(), executable: msi, profile: GameProfile(), detectedAPIs: []),
                                              in: f.context(.standard, host: host))
            #expect(plan.arguments == ["msiexec", "/i", msi.path])
            #expect(plan.workingDirectory == msi.deletingLastPathComponent())
        }
    }

    @Test func metalFXOnlyAppliesToD3DMetal() throws {
        try withTempDir { root in
            let f = try fixture(root)
            let context = f.context(.standard, host: host)
            let dx12 = GameLaunch(gameID: UUID(), executable: f.exe, profile: GameProfile(metalFX: true, metalHUD: true), detectedAPIs: [.d3d12, .d3d11])
            let plan = try LaunchPlanner.plan(dx12, in: context)
            #expect(plan.backend == .d3dmetal)
            #expect(plan.environment["D3DM_ENABLE_METALFX"] == "1")
            #expect(plan.environment["MTL_HUD_ENABLED"] == "1")

            var forcedDXMT = dx12
            forcedDXMT.profile.backendOverride = .dxmt
            #expect(try LaunchPlanner.plan(forcedDXMT, in: context).environment["D3DM_ENABLE_METALFX"] == nil)
        }
    }

    @Test func engineSettingsThenUserEnvironmentWin() throws {
        try withTempDir { root in
            let f = try fixture(root)
            var engine = f.engine
            engine.backendEnvironment[.d3dmetal] = ["WINEDLLPATH": "/gptk/wine"]
            engine.backendDLLOverrides[.d3dmetal] = ["d3d12": "b"]
            let profile = GameProfile(environment: ["WINEDEBUG": "+loaddll"])
            let game = GameLaunch(gameID: UUID(), executable: f.exe, profile: profile, detectedAPIs: [.d3d12])
            let plan = try LaunchPlanner.plan(game, in: f.context(.standard, engine: engine, host: host))
            #expect(plan.environment["WINEDLLPATH"] == "/gptk/wine")
            #expect(plan.environment["WINEDLLOVERRIDES"] == "d3d12=b;winemenubuilder.exe=")
            #expect(plan.environment["WINEDEBUG"] == "+loaddll")
        }
    }

    @Test func arm64EngineDoesNotTalkToRosetta() throws {
        try withTempDir { root in
            let f = try fixture(root)
            var engine = f.engine
            engine.architecture = .arm64
            let game = GameLaunch(gameID: UUID(), executable: f.exe, profile: GameProfile(), detectedAPIs: [.d3d11])
            #expect(try LaunchPlanner.plan(game, in: f.context(.standard, engine: engine, host: host)).environment["ROSETTA_ADVERTISE_AVX"] == nil)
        }
    }

    @Test func isolatedBottleRunsInsideTheSandbox() throws {
        try withTempDir { root in
            let f = try fixture(root)
            let game = GameLaunch(gameID: UUID(), executable: f.exe, profile: GameProfile(), detectedAPIs: [.d3d11])
            let plan = try LaunchPlanner.plan(game, in: f.context(.isolated, host: host))
            let profile = try #require(plan.sandboxProfile)

            #expect(plan.executable.path == "/usr/bin/sandbox-exec")
            #expect(plan.arguments.prefix(4) == ["-p", profile, f.engine.wine.path, f.exe.path])
            #expect(plan.environment["HOME"] == f.location.home.path)
            #expect(plan.environment["CORKSCREW_NO_LOADER_LINK"] == "1")
            #expect(profile.contains(#"(subpath "\#(SandboxProfile.canonicalPath(f.location.prefix))")"#))
            #expect(!profile.contains(#"(subpath "\#(SandboxProfile.canonicalPath(f.location.directory))")"#),
                    "the bottle folder holds bottle.json and the clean snapshot; it must not be writable")
            let server = try WineServer.directory(forPrefix: f.location.prefix, base: f.paths.wineServerDirectory)
            #expect(profile.contains(SandboxProfile.canonicalPath(server)))
            #expect(profile.contains("(deny network* (remote ip))"))
        }
    }

    @Test func isolatedBottleRefusesExecutablesOutsideIt() throws {
        try withTempDir { root in
            let f = try fixture(root)
            let outside = root.appending(path: "Downloads/Setup.exe")
            try outside.write(PEBuilder().build())
            let game = GameLaunch(gameID: UUID(), executable: outside, profile: GameProfile(), detectedAPIs: [])
            #expect(throws: LaunchError.executableOutsideIsolatedBottle(outside.path)) {
                try LaunchPlanner.plan(game, in: f.context(.isolated, host: host))
            }
        }
    }

    @Test func setupCommandsShareTheBottlesSandbox() throws {
        try withTempDir { root in
            let f = try fixture(root)
            let isolated = try LaunchPlanner.plan(wineArguments: ["wineboot", "--init"], in: f.context(.isolated, host: host))
            #expect(isolated.executable.path == "/usr/bin/sandbox-exec")
            #expect(isolated.arguments.suffix(2) == ["wineboot", "--init"])

            let standard = try LaunchPlanner.plan(wineArguments: ["wineboot", "--init"], in: f.context(.standard, host: host))
            #expect(standard.executable == f.engine.wine)
            #expect(standard.arguments == ["wineboot", "--init"])
            #expect(standard.environment["WINEDLLPATH"] == f.engine.wined3dDLLs.path)
        }
    }

    @Test func wineServerDirectoryFollowsWineNaming() throws {
        try withTempDir { root in
            let prefix = try root.appending(path: "prefix").makeDirectory()
            var info = stat()
            #expect(stat(prefix.path, &info) == 0)
            let dir = try WineServer.directory(forPrefix: prefix, base: URL(fileURLWithPath: "/tmp/.wine-501"))
            #expect(dir.lastPathComponent == "server-\(String(info.st_dev, radix: 16))-\(String(info.st_ino, radix: 16))")
            #expect(throws: WineServer.LocateError.self) {
                try WineServer.directory(forPrefix: root.appending(path: "missing"), base: URL(fileURLWithPath: "/tmp/.wine-501"))
            }
        }
    }
}
