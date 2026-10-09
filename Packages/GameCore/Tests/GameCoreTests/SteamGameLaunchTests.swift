import Foundation
import Testing
@testable import GameCore

struct SteamGameLaunchTests {
    @Test func recognizesSteamAndAGamesPrograms() {
        #expect(BottleProcesses.isSteamClient(#"c:\program files (x86)\steam\steam.exe"#))
        #expect(!BottleProcesses.isSteamClient(#"c:\program files (x86)\steam\bin\cef\cef.win64\steamwebhelper.exe"#))
        let rdr2 = "Red Dead Redemption 2"
        #expect(BottleProcesses.isFromSteamGame(
            #"c:\program files (x86)\steam\steamapps\common\red dead redemption 2\rdr2.exe"#, installDir: rdr2))
        #expect(BottleProcesses.isFromSteamGame(#"d:\steamlibrary\steamapps\common\red dead redemption 2\playrdr2.exe"#,
                                                installDir: rdr2), "any library folder")
        #expect(!BottleProcesses.isFromSteamGame(#"c:\program files\rockstar games\launcher\launcher.exe"#, installDir: rdr2))
        #expect(!BottleProcesses.isFromSteamGame(
            #"c:\program files (x86)\steam\steamapps\common\red dead redemption 2 extra\x.exe"#, installDir: rdr2))
    }

    @Test func readsAProcesssArgumentsAndEnvironment() throws {
        let process = try #require(BottleProcesses.processArguments(of: getpid()))
        #expect(process.arguments.first == CommandLine.arguments.first)
        #expect(process.environment["HOME"] == ProcessInfo.processInfo.environment["HOME"])
    }

    @Test func knowsASteamGamesFolderAndLauncher() throws {
        try withTempDir { prefix in
            let steam = prefix.appending(path: "drive_c/Program Files (x86)/Steam")
            try steam.appending(path: "steam.exe").write(PEBuilder().build())
            try steam.appending(path: "steamapps/appmanifest_1174180.acf").write(
                "\"AppState\"\n{\n\t\"appid\"\t\t\"1174180\"\n\t\"name\"\t\t\"Red Dead Redemption 2\"\n\t\"installdir\"\t\t\"Red Dead Redemption 2\"\n}")
            let folder = steam.appending(path: "steamapps/common/Red Dead Redemption 2")
            try folder.appending(path: "Redistributables/Rockstar-Games-Launcher.exe").write(PEBuilder().build())
            let client = steam.appending(path: "steam.exe")

            let game = try #require(Launcher.steamGameLaunch(
                executable: client, arguments: ["-noverifyfiles", "-silent", "-applaunch", "1174180"], prefix: prefix))
            #expect(game == Launcher.SteamGameLaunch(installDir: "Red Dead Redemption 2", steamWasRunning: false,
                                                     usesRockstarLauncher: true))
            #expect(Launcher.steamGameLaunch(executable: client, arguments: ["-silent"], prefix: prefix) == nil, "Steam itself")
            #expect(Launcher.steamGameLaunch(executable: client, arguments: ["-applaunch", "999"], prefix: prefix) == nil)
        }
    }

    @Test func aGameHasQuitOnceItsProgramsStayGone() async throws {
        // Checks elapsed time, not poll counts: on a busy CI runner a 10 ms sleep can take far longer.
        let clock = ContinuousClock()

        // Seen for three polls, then gone: quit after the grace period.
        var polls = 0
        var lastSeen = clock.now
        let quit = try await Launcher.waitForQuit(timeout: .seconds(5), grace: .milliseconds(30), poll: .milliseconds(10)) {
            polls += 1
            let running = (2...4).contains(polls)
            if running { lastSeen = clock.now }
            return running
        }
        #expect(quit)
        #expect(polls > 4)
        #expect(clock.now - lastSeen >= .milliseconds(30), "waited out the grace period")

        // A restart within the grace period doesn't count as quitting. The grace is generous so the
        // two-poll gap stays inside it on a slow machine.
        polls = 0
        let restarted = try await Launcher.waitForQuit(timeout: .seconds(5), grace: .milliseconds(500), poll: .milliseconds(10)) {
            polls += 1
            let running = polls == 1 || (4...6).contains(polls)
            if running { lastSeen = clock.now }
            return running
        }
        #expect(restarted)
        #expect(polls > 6, "the second run is the one that ended")
        #expect(clock.now - lastSeen >= .milliseconds(500))

        // Never started: give up after the timeout, leaving the launch open.
        let never = try await Launcher.waitForQuit(timeout: .milliseconds(50), grace: .milliseconds(10), poll: .milliseconds(10)) { false }
        #expect(never == false)
    }
}
