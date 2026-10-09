import Foundation
import Testing
@testable import GameCore

struct SteamTests {
    /// A bottle prefix with Steam, two games in its own library, a tool without a program, a game
    /// still downloading, and a second library folder on D:.
    private func makeSteam(in root: URL) throws -> (prefix: URL, steam: URL) {
        let prefix = root.appending(path: "prefix")
        let steam = prefix.appending(path: "drive_c/Program Files (x86)/Steam")
        var client = PEBuilder()
        client.resources = [3: [(id: 1, data: [1, 2, 3, 4])], 14: [(id: 1, data: PEBuilder.iconGroup([(id: 1, width: 32, size: 4)]))]]
        try steam.appending(path: "steam.exe").write(client.build())

        func app(_ id: String, _ name: String, folder: String, in library: URL, stateFlags: Int = 4) throws {
            try library.appending(path: "steamapps/appmanifest_\(id).acf").write("""
            "AppState"
            {
            \t"appid"\t\t"\(id)"
            \t"name"\t\t"\(name)"
            \t"StateFlags"\t\t"\(stateFlags)"
            \t"installdir"\t\t"\(folder)"
            }
            """)
        }
        try app("3132990", "Black Myth: Wukong Benchmark Tool", folder: "Black Myth Wukong Benchmark Tool", in: steam)
        try steam.appending(path: "steamapps/common/Black Myth Wukong Benchmark Tool/b1_benchmark.exe")
            .write(PEBuilder(imports: ["d3d12.dll"]).build())
        try app("417860", "Emily is Away", folder: "Emily is Away", in: steam)
        let emily = steam.appending(path: "steamapps/common/Emily is Away")
        try emily.appending(path: "Emily is Away.exe").write(PEBuilder(machine: 0x014C, pe32Plus: false, imports: ["d3d11.dll"]).build())
        try emily.appending(path: "UnityCrashHandler32.exe").write(PEBuilder(machine: 0x014C, pe32Plus: false).build() + Data(count: 4096))
        try app("228980", "Steamworks Common Redistributables", folder: "Steamworks Shared", in: steam)
        try steam.appending(path: "steamapps/common/Steamworks Shared/_CommonRedist/vcredist.exe").write(PEBuilder().build())
        // Downloading (StateFlags 1026): Steam stages its files under steamapps/downloading.
        try app("1174180", "Red Dead Redemption 2", folder: "Red Dead Redemption 2", in: steam, stateFlags: 1026)
        try steam.appending(path: "steamapps/downloading/1174180/RDR2.exe").write(PEBuilder(imports: ["vulkan-1.dll"]).build())

        let games = root.appending(path: "Games Drive")
        try app("620", "Portal 2", folder: "Portal 2", in: games.appending(path: "SteamLibrary"))
        try games.appending(path: "SteamLibrary/steamapps/common/Portal 2/portal2.exe").write(PEBuilder(imports: ["d3d9.dll"]).build())
        try prefix.appending(path: "dosdevices").makeDirectory()
        try FileManager.default.createSymbolicLink(at: prefix.appending(path: "dosdevices/d:"), withDestinationURL: games)
        try FileManager.default.createSymbolicLink(at: prefix.appending(path: "dosdevices/c:"), withDestinationURL: prefix.appending(path: "drive_c"))
        try steam.appending(path: "steamapps/libraryfolders.vdf").write(#"""
        "libraryfolders"
        {
        	"0"
        	{
        		"path"		"C:\\Program Files (x86)\\Steam"
        	}
        	"1"
        	{
        		"path"		"D:\\SteamLibrary"
        	}
        }
        """#)
        return (prefix, steam)
    }

    @Test func listsSteamAndItsGamesWithTheirSettings() throws {
        try withTempDir { root in
            let (prefix, steam) = try makeSteam(in: root)
            let bottle = Bottle(name: "Games", kind: .standard, engineID: "winecx-test")
            let entries = Steam.libraryEntries(for: bottle, prefix: prefix)
            let client = steam.appending(path: "steam.exe")

            #expect(entries.map(\.name) == ["Steam", "Black Myth: Wukong Benchmark Tool", "Emily is Away", "Portal 2"])
            #expect(entries.allSatisfy { $0.executable == client && $0.bottleID == bottle.id })
            #expect(entries.map(\.storeKey) == ["client", "3132990", "417860", "620"].map { "steam:\(bottle.id.uuidString):\($0)" })

            // Steam itself: the tested Wukong setup, so games started from its window inherit it, but
            // without Retina mode (its window is drawn in software).
            #expect(entries[0].profile == GameProfile(backendOverride: .d3dmetal, metalFX: true, retinaMode: false,
                                                      arguments: ["-noverifyfiles", "-norepairfiles"]))
            // Games start Steam without its window.
            #expect(entries[1].profile == GameProfile(backendOverride: .d3dmetal, metalFX: true, retinaMode: true,
                                                      arguments: ["-noverifyfiles", "-norepairfiles", "-silent", "-applaunch", "3132990"]))
            // Emily is Away (32-bit DX11) is tested on DXVK; untested games get the backend detected
            // from their own program (DX9 → WineD3D, below).
            #expect(entries[2].profile.backendOverride == .dxvk)
            #expect(entries[2].profile.metalFX == false)
            #expect(entries[2].profile.retinaMode == false)
            #expect(entries[2].iconSource?.lastPathComponent == "Emily is Away.exe", "named like the game, not the biggest .exe")
            #expect(entries[3].profile.backendOverride == .wined3d)
            #expect(entries[3].profile.arguments.suffix(2) == ["-applaunch", "620"])
        }
    }

    @Test func knowsWhichGamesAreInstalled() throws {
        try withTempDir { root in
            let (prefix, steam) = try makeSteam(in: root)
            let bottle = Bottle(name: "Games", kind: .standard, engineID: "winecx-test")
            let states = Steam.installStates(for: bottle, prefix: prefix)
            func state(_ appID: String) -> Steam.InstallState {
                states[StoreItem(store: "steam", appID: appID).key(in: bottle.id)] ?? .notInstalled
            }
            #expect(state("3132990") == .installed)
            #expect(state("620") == .installed, "in the second library folder")
            #expect(state("1174180") == .downloading)

            // Uninstalling removes the manifest (and the game's folder).
            try FileManager.default.removeItem(at: steam.appending(path: "steamapps/appmanifest_3132990.acf"))
            let after = Steam.installStates(for: bottle, prefix: prefix)
            #expect(after[StoreItem(store: "steam", appID: "3132990").key(in: bottle.id)] == nil)
            #expect(Steam.libraryEntries(for: bottle, prefix: prefix).map(\.store?.appID) == [nil, "417860", "620"])
        }
    }

    @Test func opensAStorePageTheWaySteamsLinkHandlerDoes() {
        #expect(Steam.storePageArguments(appID: "3132990") == ["-noverifyfiles", "-norepairfiles", "--", "steam://store/3132990"])
    }

    @Test func skipsEntriesTheLibraryAlreadyKnows() throws {
        try withTempDir { root in
            let (prefix, _) = try makeSteam(in: root)
            let bottle = Bottle(name: "Games", kind: .standard, engineID: "winecx-test")
            let known = Set(["client", "417860"].map { "steam:\(bottle.id.uuidString):\($0)" })
            #expect(Steam.libraryEntries(for: bottle, prefix: prefix, excluding: known).map(\.store?.appID) == ["3132990", "620"])
        }
    }

    /// Tested games are listed before they're downloaded, with their tested settings; installed ones aren't doubled.
    @Test func listsTestedGamesThatArentInstalled() throws {
        try withTempDir { root in
            let (prefix, _) = try makeSteam(in: root)
            let bottle = Bottle(name: "Games", kind: .standard, engineID: "winecx-test")
            let entries = Steam.libraryEntries(for: bottle, prefix: prefix, includeTested: true)
            // Wukong (3132990) and Emily (417860) are installed here; RDR2 (1174180) is still downloading.
            #expect(entries.map(\.store?.appID) == [nil, "3132990", "417860", "620", "1174180"])
            let rdr2 = try #require(entries.last)
            #expect(rdr2.name == "Red Dead Redemption 2")
            #expect(rdr2.profile.backendOverride == .d3dmetal)
            #expect(rdr2.profile.arguments.suffix(2) == ["-applaunch", "1174180"])
            #expect(entries.filter { $0.store?.appID == "3132990" }.count == 1)
            #expect(Steam.libraryEntries(for: bottle, prefix: prefix).map(\.store?.appID).contains("1174180") == false)
        }
    }

    @Test func noEntriesWithoutSteam() throws {
        try withTempDir { root in
            #expect(Steam.libraryEntries(for: Bottle(name: "Empty", kind: .standard, engineID: "x"), prefix: root).isEmpty)
        }
    }

    @Test func keepsTheWebHelperWrapperInFront() throws {
        try withTempDir { root in
            let steam = root.appending(path: "Steam")
            let cef = steam.appending(path: "bin/cef/cef.win64")
            // Like the real wrapper, it names the program it starts (UTF-16).
            let marker = Array("steamwebhelper_real.exe".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
            let wrapper = root.appending(path: "wrapper.exe")
            try wrapper.write(Data(Array("wrapper".utf8) + marker))
            #expect(try Steam.installWebHelperWrapper(steamRoot: steam, wrapper: wrapper) == false, "Steam hasn't downloaded it yet")

            try cef.appending(path: "steamwebhelper.exe").write("steam's helper")
            #expect(try Steam.installWebHelperWrapper(steamRoot: steam, wrapper: wrapper))
            #expect(FileManager.default.contentsEqual(atPath: cef.appending(path: "steamwebhelper.exe").path, andPath: wrapper.path))
            #expect(try String(contentsOf: cef.appending(path: "steamwebhelper_real.exe"), encoding: .utf8) == "steam's helper")
            #expect(try Steam.installWebHelperWrapper(steamRoot: steam, wrapper: wrapper) == false)

            // Another build of the wrapper (a different timestamp) is replaced, never kept as the real helper.
            try FileManager.default.removeItem(at: cef.appending(path: "steamwebhelper.exe"))
            try cef.appending(path: "steamwebhelper.exe").write(Data(Array("older wrapper build".utf8) + marker))
            #expect(try Steam.installWebHelperWrapper(steamRoot: steam, wrapper: wrapper) == false)
            #expect(FileManager.default.contentsEqual(atPath: cef.appending(path: "steamwebhelper.exe").path, andPath: wrapper.path))
            #expect(try String(contentsOf: cef.appending(path: "steamwebhelper_real.exe"), encoding: .utf8) == "steam's helper")

            // A Steam update puts its (newer) helper back.
            try FileManager.default.removeItem(at: cef.appending(path: "steamwebhelper.exe"))
            try cef.appending(path: "steamwebhelper.exe").write("steam's newer helper")
            #expect(try Steam.installWebHelperWrapper(steamRoot: steam, wrapper: wrapper))
            #expect(try String(contentsOf: cef.appending(path: "steamwebhelper_real.exe"), encoding: .utf8) == "steam's newer helper")

            // A fresh Steam may run its other CEF build (cef.win7x64); that one gets the wrapper too.
            let win7 = steam.appending(path: "bin/cef/cef.win7x64")
            try win7.appending(path: "steamwebhelper.exe").write("steam's win7 helper")
            #expect(try Steam.installWebHelperWrapper(steamRoot: steam, wrapper: wrapper))
            #expect(FileManager.default.contentsEqual(atPath: win7.appending(path: "steamwebhelper.exe").path, andPath: wrapper.path))
            #expect(try String(contentsOf: win7.appending(path: "steamwebhelper_real.exe"), encoding: .utf8) == "steam's win7 helper")
        }
    }

    @Test func readsValveKeyValues() {
        let text = "\"AppState\"\n{\n\t\"appid\"\t\t\"620\"\n\t\"name\"\t\t\"Portal 2\"\n\t\"path\"\t\t\"D:\\\\Games\\\\Steam\"\n}"
        #expect(Steam.value("appid", in: text) == "620")
        #expect(Steam.value("NAME", in: text) == "Portal 2")
        #expect(Steam.value("path", in: text) == #"D:\Games\Steam"#)
        #expect(Steam.value("missing", in: text) == nil)
        #expect(Steam.windowsPath(#"D:\Games\Steam"#, prefix: URL(fileURLWithPath: "/p"))?.path == "/p/dosdevices/d:/Games/Steam")
    }

    /// `-noverifyfiles` also skips Steam's first download; until `steamui.dll` is there, Steam starts without it.
    @Test func freshSteamStartsWithoutTheSkipFlags() throws {
        try withTempDir { root in
            let arguments = Steam.clientArguments + ["-silent"]
            #expect(Steam.launchArguments(arguments, steamRoot: root) == ["-silent"])
            try root.appending(path: "steamui.dll").write("MZ")
            #expect(Steam.launchArguments(arguments, steamRoot: root) == arguments)
        }
    }
}
