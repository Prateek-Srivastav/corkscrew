import Foundation
import Testing
@testable import GameCore

struct LibraryTests {
    @Test func savesAndLoadsTheLibrary() throws {
        try withTempDir { root in
            let store = LibraryStore(paths: RuntimeStoreTests.paths(root))
            #expect(try store.load() == Library())

            let game = Game(name: "Demo", executable: root.appending(path: "Demo/Demo.exe"), bottleID: UUID(),
                            profile: GameProfile(backendOverride: .dxmt, performanceOverlay: true, arguments: ["-dx11"]),
                            addedAt: Date(timeIntervalSince1970: 1_800_000_000),
                            store: StoreItem(store: "steam", appID: "42"), iconSource: root.appending(path: "Demo/Icon.exe"))
            let library = Library(games: [game], removedStoreItems: ["steam:x:client"])
            try store.save(library)
            #expect(try store.load() == library)

            // Files from before store entries existed still load.
            try RuntimeStoreTests.paths(root).library.write(#"{"games": []}"#)
            #expect(try store.load() == Library())
        }
    }

    @Test func storeEntriesAreAddedOnceAndStayRemoved() {
        let bottle = UUID()
        let steam = Game(name: "Steam", executable: URL(fileURLWithPath: "/b/steam.exe"), bottleID: bottle, store: StoreItem(store: "steam"))
        let wukong = Game(name: "Wukong", executable: steam.executable, bottleID: bottle, store: StoreItem(store: "steam", appID: "3132990"))
        var library = Library(games: [Game(name: "Mine", executable: URL(fileURLWithPath: "/b/mine.exe"), bottleID: bottle)])

        #expect(library.addMissing([steam, wukong]).map(\.name) == ["Steam", "Wukong"])
        // Found again on the next launch (with new ids): nothing changes.
        let again = [steam, wukong].map { var copy = $0; copy.id = UUID(); return copy }
        #expect(library.addMissing(again).isEmpty)
        #expect(library.games.count == 3)

        library.remove(wukong.id)
        #expect(library.addMissing(again).isEmpty, "a removed store entry stays removed")
        #expect(library.games.map(\.name) == ["Mine", "Steam"])
    }

    @Test func storeEntriesSavedWithOlderSettingsAreUpgradedOnce() throws {
        try withTempDir { root in
            let store = LibraryStore(paths: RuntimeStoreTests.paths(root))
            let bottle = UUID()
            let client = URL(fileURLWithPath: "/b/steam.exe")
            let steam = Game(name: "Steam", executable: client, bottleID: bottle,
                             profile: GameProfile(backendOverride: .d3dmetal, metalFX: true, retinaMode: true, arguments: ["-noverifyfiles"]),
                             store: StoreItem(store: "steam"))
            let wukong = Game(name: "Wukong", executable: client, bottleID: bottle,
                              profile: GameProfile(retinaMode: true, arguments: ["-noverifyfiles", "-applaunch", "3132990"]),
                              store: StoreItem(store: "steam", appID: "3132990"))
            let mine = Game(name: "Mine", executable: URL(fileURLWithPath: "/b/mine.exe"), bottleID: bottle,
                            profile: GameProfile(retinaMode: true))
            // A library saved before settings versions existed.
            var json = try JSONSerialization.jsonObject(with: JSONEncoder.bottles.encode(Library(games: [steam, wukong, mine]))) as! [String: Any]
            json["storeSettingsVersion"] = nil
            try RuntimeStoreTests.paths(root).library.write(JSONSerialization.data(withJSONObject: json))

            var library = try store.load()
            #expect(library.storeSettingsVersion == Steam.settingsVersion)
            #expect(library.games[0].profile.retinaMode == false, "Steam's window is drawn in software")
            #expect(library.games[0].profile.metalFX, "other settings stay")
            #expect(library.games[1].profile.arguments == ["-noverifyfiles", "-silent", "-applaunch", "3132990"])
            #expect(library.games[1].profile.retinaMode)
            #expect(library.games[2].profile == mine.profile, "programs the user added aren't touched")

            // Once saved, the user's own choices stay.
            library.games[0].profile.retinaMode = true
            try store.save(library)
            #expect(try store.load().games[0].profile.retinaMode)
        }
    }

    @Test func profilesSavedBeforeASettingExistedGetItsDefault() throws {
        let profile = try JSONDecoder().decode(GameProfile.self, from: Data(#"{"metalHUD": true, "backendOverride": "dxvk"}"#.utf8))
        #expect(profile == GameProfile(backendOverride: .dxvk, metalHUD: true))
        #expect(try JSONDecoder().decode(GameProfile.self, from: Data("{}".utf8)) == GameProfile())
    }

    @Test func cachesTheIconSoItSurvivesTheExecutableMoving() throws {
        try withTempDir { root in
            let store = LibraryStore(paths: RuntimeStoreTests.paths(root))
            var pe = PEBuilder()
            pe.resources = [3: [(id: 1, data: [1, 2, 3, 4])], 14: [(id: 1, data: PEBuilder.iconGroup([(id: 1, width: 32, size: 4)]))]]
            let exe = root.appending(path: "Demo.exe")
            try exe.write(pe.build())
            let game = Game(name: "Demo", executable: exe, bottleID: UUID())

            var icon = try #require(store.icon(for: game))

            // An updated program brings its new icon.
            pe.resources[3] = [(id: 1, data: [5, 6, 7, 8])]
            try exe.write(pe.build())
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(60)], ofItemAtPath: exe.path)
            let updated = try #require(store.icon(for: game))
            #expect(updated != icon)
            icon = updated

            try FileManager.default.removeItem(at: exe)
            #expect(store.icon(for: game) == icon)
            store.removeCachedIcon(for: game)
            #expect(store.icon(for: game) == nil)
        }
    }

    @Test func namesGamesAfterTheirFolderOrFile() throws {
        try withTempDir { root in
            #expect(Game.defaultName(for: root.appending(path: "Games/Celeste/Celeste.exe")) == "Celeste")
            // Unreal 4/5: <Game>/<Project>/Binaries/Win64/<Project>-Win64-Shipping.exe
            let shipping = root.appending(path: "Black Myth/b1/Binaries/Win64/b1-Win64-Shipping.exe")
            try shipping.write(PEBuilder().build())
            #expect(Game.defaultName(for: shipping) == "Black Myth")
        }
    }

    @Test func launchLogsAreListedNewestFirst() throws {
        try withTempDir { root in
            let paths = RuntimeStoreTests.paths(root)
            let id = UUID()
            let older = LaunchLogs.fileName(startedAt: Date(timeIntervalSince1970: 1_800_000_000))
            let newer = LaunchLogs.fileName(startedAt: Date(timeIntervalSince1970: 1_800_000_060))
            for name in [older, newer, "retina.log"] { try paths.logs(for: id).appending(path: name).write("x") }
            #expect(LaunchLogs.list(for: id, paths: paths).map(\.lastPathComponent) == [newer, older])
        }
    }
}
