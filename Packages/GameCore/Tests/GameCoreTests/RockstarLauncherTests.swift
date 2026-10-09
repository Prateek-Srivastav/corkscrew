import Foundation
import Testing
@testable import GameCore

struct RockstarLauncherTests {
    private func builtin(_ name: String) -> Data {
        Data(count: 0x40) + Data("Wine builtin DLL".utf8) + Data(name.utf8)
    }

    @Test func copiesWinesDirect3DIntoSystem32AsPlainDLLs() throws {
        try withTempDir { root in
            let runtime = root.appending(path: "runtime")
            let wined3d = runtime.appending(path: "lib/wine-backends/wined3d/x86_64-windows")
            for dll in RockstarLauncher.dlls { try wined3d.appending(path: "\(dll).dll").write(builtin(dll)) }
            let engine = Engine(id: "winecx-test", root: runtime, architecture: .x86_64)
            let prefix = root.appending(path: "prefix")
            let system32 = prefix.appending(path: "drive_c/windows/system32")
            try system32.appending(path: "dxgi.dll").write(builtin("dxgi"))

            #expect(try RockstarLauncher.installDLLs(prefix: prefix, engine: engine))
            let dxgi = try Data(contentsOf: system32.appending(path: "dxgi.dll"))
            #expect(dxgi == Data(count: 0x50) + Data("dxgi".utf8), "the builtin mark is gone, the rest is Wine's")
            #expect(FileManager.default.fileExists(atPath: system32.appending(path: "d3d12core.dll").path))
            #expect(try RockstarLauncher.installDLLs(prefix: prefix, engine: engine) == false, "nothing to do the second time")

            // Updating the bottle puts Wine's builtin back.
            try system32.appending(path: "d3d11.dll").write(builtin("d3d11"))
            #expect(try RockstarLauncher.installDLLs(prefix: prefix, engine: engine))
        }
    }

    @Test func isNeededOnceAGameShipsTheLauncherOrItsInstalled() throws {
        try withTempDir { root in
            let prefix = root.appending(path: "prefix")
            let steam = prefix.appending(path: "drive_c/Program Files (x86)/Steam")
            try steam.appending(path: "steam.exe").write(PEBuilder().build())
            try steam.appending(path: "steamapps/appmanifest_1174180.acf").write(
                "\"AppState\"\n{\n\t\"appid\"\t\t\"1174180\"\n\t\"name\"\t\t\"Red Dead Redemption 2\"\n\t\"installdir\"\t\t\"Red Dead Redemption 2\"\n}")
            let game = steam.appending(path: "steamapps/common/Red Dead Redemption 2")
            try game.appending(path: "RDR2.exe").write(PEBuilder().build())
            #expect(RockstarLauncher.isNeeded(prefix: prefix) == false)

            try game.appending(path: "Redistributables/Rockstar-Games-Launcher.exe").write(PEBuilder().build())
            #expect(RockstarLauncher.isNeeded(prefix: prefix), "Steam installs it on the game's first launch")

            try FileManager.default.removeItem(at: game.appending(path: "Redistributables"))
            try prefix.appending(path: "drive_c/Program Files/Rockstar Games/Launcher/Launcher.exe").write(PEBuilder().build())
            #expect(RockstarLauncher.isNeeded(prefix: prefix))
        }
    }

    @Test func registrySettingsForBothPrograms() throws {
        let file = RockstarLauncher.registryFile
        #expect(file.contains(#"[HKEY_CURRENT_USER\Software\Wine\AppDefaults\Launcher.exe\DllOverrides]"#))
        #expect(file.contains(#"[HKEY_CURRENT_USER\Software\Wine\AppDefaults\SocialClubHelper.exe\Direct3D]"#))
        #expect(file.contains(#""d3d12core"="native""#))
        #expect(file.contains(#""nvapi64"="""#), "D3DMetal's NVIDIA stand-in is off for them")
        #expect(RockstarLauncher.overrides(for: "Launcher.exe").first { $0.dll == "d3d11" }?.order == "native")
        #expect(RockstarLauncher.overrides(for: "SocialClubHelper.exe").first { $0.dll == "d3d11" }?.order == "",
                "Chromium draws in software")

        try withTempDir { root in
            // What wineserver saves after importing it.
            var saved = "WINE REGISTRY Version 2\n"
            for program in RockstarLauncher.programs {
                saved += "\n[Software\\\\Wine\\\\AppDefaults\\\\\(program)\\\\Direct3D] 1791420451\n\"renderer\"=\"gl\"\n"
                saved += "\n[Software\\\\Wine\\\\AppDefaults\\\\\(program)\\\\DllOverrides] 1791420451\n"
                saved += RockstarLauncher.overrides(for: program).map { "\"\($0.dll)\"=\"\($0.order)\"\n" }.joined()
            }
            try root.appending(path: "user.reg").write(saved)
            #expect(RockstarLauncher.isRegistrySet(prefix: root))
            try root.appending(path: "user.reg").write(saved.replacingOccurrences(of: "\"d3d12core\"=\"native\"", with: ""))
            #expect(RockstarLauncher.isRegistrySet(prefix: root) == false)
            // Saved before the vendor libraries were turned off: set again.
            try root.appending(path: "user.reg").write(saved.replacingOccurrences(of: "\"nvapi64\"=\"\"", with: ""))
            #expect(RockstarLauncher.isRegistrySet(prefix: root) == false)
        }
    }

    @Test func rdr2RunsOnDirectX12() throws {
        try withTempDir { prefix in
            let file = RockstarLauncher.rdr2Settings(prefix: prefix)

            // Before the first launch: the tested settings.
            #expect(try RockstarLauncher.ensureDX12(prefix: prefix))
            #expect(try String(contentsOf: file, encoding: .utf8) == RockstarLauncher.rdr2TestedSettings)
            #expect(try RockstarLauncher.ensureDX12(prefix: prefix) == false, "they already use DirectX 12")

            // The game's own file, switched to Vulkan in its menu: only the API changes.
            let vulkan = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n\r\n<rage__fwuiSystemSettingsCollection>\r\n"
                + "  <advancedGraphics>\r\n    <API>kSettingAPI_Vulkan</API>\r\n    <locked value=\"true\" />\r\n"
                + "  </advancedGraphics>\r\n</rage__fwuiSystemSettingsCollection>"
            try file.write(vulkan)
            #expect(try RockstarLauncher.ensureDX12(prefix: prefix))
            #expect(try String(contentsOf: file, encoding: .utf8)
                    == vulkan.replacingOccurrences(of: "kSettingAPI_Vulkan", with: "kSettingAPI_DX12"))
            #expect(try RockstarLauncher.ensureDX12(prefix: prefix) == false, "nothing to do the second time")
        }
    }

    @Test func rdr2sBorderlessWindowFillsTheDesktop() throws {
        try withTempDir { prefix in
            let file = RockstarLauncher.rdr2Settings(prefix: prefix)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            func settings(windowed: String, width: Int, height: Int) -> String {
                ["<rage__fwuiSystemSettingsCollection>", "  <video>", "    <resolutionIndex value=\"0\" />",
                 "    <screenWidth value=\"\(width)\" />", "    <screenHeight value=\"\(height)\" />",
                 "    <screenWidthWindowed value=\"\(width)\" />", "    <screenHeightWindowed value=\"\(height)\" />",
                 "    <windowed value=\"\(windowed)\" />", "  </video>", "</rage__fwuiSystemSettingsCollection>"]
                    .joined(separator: "\r\n")
            }
            let desktop = (width: 1512, height: 982)

            // Safe Mode's borderless 1147×745: a small window mid-screen.
            try file.write(settings(windowed: "2", width: 1147, height: 745))
            #expect(try RockstarLauncher.fitWindow(prefix: prefix, desktop: desktop))
            #expect(try String(contentsOf: file, encoding: .utf8) == settings(windowed: "2", width: 1512, height: 982))
            #expect(try RockstarLauncher.fitWindow(prefix: prefix, desktop: desktop) == false, "nothing to do the second time")

            // Fullscreen and windowed keep the player's resolution, except for the tested settings'
            // first launch.
            for windowed in ["0", "1"] {
                try file.write(settings(windowed: windowed, width: 1147, height: 745))
                #expect(try RockstarLauncher.fitWindow(prefix: prefix, desktop: desktop) == false)
                #expect(try RockstarLauncher.fitWindow(prefix: prefix, desktop: desktop, anyScreenType: true))
                #expect(try String(contentsOf: file, encoding: .utf8) == settings(windowed: windowed, width: 1512, height: 982))
            }
            try FileManager.default.removeItem(at: file)
            #expect(try RockstarLauncher.fitWindow(prefix: prefix, desktop: desktop, anyScreenType: true) == false, "no settings yet")
        }
    }

    @Test func rdr2sTestedSettingsFitAnyMac() throws {
        let settings = RockstarLauncher.rdr2TestedSettings
        #expect(settings.contains("<API>kSettingAPI_DX12</API>"))
        #expect(RockstarLauncher.settingValue("windowed", in: settings) == RockstarLauncher.fullscreen)
        #expect(!settings.contains("\r"), "line endings as the game writes them")
        for machineSpecific in ["refreshRate", "videoCardDescription"] {
            #expect(!settings.contains(machineSpecific), "the game fills in \(machineSpecific) for each Mac")
        }

        // Made on a 1512×982 desktop: on their first launch they get this Mac's, also in fullscreen.
        try withTempDir { prefix in
            try RockstarLauncher.ensureDX12(prefix: prefix)
            #expect(try RockstarLauncher.fitWindow(prefix: prefix, desktop: (width: 1800, height: 1169)) == false,
                    "later launches keep the player's fullscreen resolution")
            #expect(try RockstarLauncher.fitWindow(prefix: prefix, desktop: (width: 1800, height: 1169), anyScreenType: true))
            let text = try String(contentsOf: RockstarLauncher.rdr2Settings(prefix: prefix), encoding: .utf8)
            for (name, value) in [("screenWidth", "1800"), ("screenHeight", "1169"),
                                  ("screenWidthWindowed", "1800"), ("screenHeightWindowed", "1169")] {
                #expect(RockstarLauncher.settingValue(name, in: text) == value)
            }
        }
    }

    @Test func noticesARuntimeWithoutTheSocialClubPatch() throws {
        try withTempDir { root in
            let engine = Engine(id: "winecx-test", root: root, architecture: .x86_64)
            let kernelbase = root.appending(path: "lib/wine/x86_64-windows/kernelbase.dll")
            try kernelbase.write(Data("MZ...Social Club browser process: %s\n...".utf8))
            #expect(RockstarLauncher.hasSocialClubPatch(engine: engine))
            try kernelbase.write(Data("MZ...".utf8))
            #expect(RockstarLauncher.hasSocialClubPatch(engine: engine) == false)
        }
    }
}
