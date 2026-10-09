import Foundation
import Testing
@testable import GameCore

struct RetinaModeTests {
    // Trimmed from a real bottle's user.reg.
    static let userReg = #"""
    WINE REGISTRY Version 2
    ;; All keys relative to REGISTRY\\User\\S-1-5-21-0-0-0-1000

    [Software\\Wine\\AppDefaults\\game.exe\\Mac Driver] 1791375586
    "RetinaMode"="n"

    [Software\\Wine\\Mac Driver] 1791375602
    #time=1dd56562de058e0
    "AllowSetGamma"=dword:00000000
    "RetinaMode"="y"

    [Software\\Wine\\Mac Driver\\Extra] 1791375603
    "Other"="1"

    """#

    @Test func readsValuesFromTheirOwnKeyOnly() {
        let value = { (name: String, key: String) in WineRegistry.value(name, inKey: key, text: Self.userReg) }
        #expect(value("RetinaMode", #"Software\Wine\Mac Driver"#) == "y")
        #expect(value("retinamode", #"SOFTWARE\Wine\mac driver"#) == "y")
        #expect(value("AllowSetGamma", #"Software\Wine\Mac Driver"#) == "dword:00000000")
        // A subkey's values and the per-app key don't leak into the parent.
        #expect(value("Other", #"Software\Wine\Mac Driver"#) == nil)
        #expect(value("RetinaMode", #"Software\Wine\AppDefaults\game.exe\Mac Driver"#) == "n")
        #expect(value("RetinaMode", #"Software\Wine\Missing"#) == nil)
    }

    @Test func readsOnOffLikeWine() {
        for on in ["y", "Yes", "t", "true", "1"] { #expect(WineRegistry.isTrue(on)) }
        for off in ["n", "no", "f", "0", "", nil] as [String?] { #expect(!WineRegistry.isTrue(off)) }
    }

    @Test func readsTheBottleSetting() throws {
        try withTempDir { prefix in
            #expect(!RetinaMode.isEnabled(prefix: prefix))  // no user.reg yet
            try prefix.appending(path: "user.reg").write(Self.userReg)
            #expect(RetinaMode.isEnabled(prefix: prefix))
            try prefix.appending(path: "user.reg").write(Self.userReg.replacingOccurrences(of: #""RetinaMode"="y""#, with: ""))
            #expect(!RetinaMode.isEnabled(prefix: prefix))  // missing means off
        }
    }

    @Test func readsReplyOfRegQuery() {
        let log = """
        # command: /runtime/bin/wine reg query HKCU\\Software\\Wine\\Mac Driver /v RetinaMode
        # WINEDEBUG=-all

        HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver
            RetinaMode    REG_SZ    y

        """
        #expect(RetinaMode.queriedValue(in: log) == "y")
        #expect(RetinaMode.queriedValue(in: log.replacingOccurrences(of: "\n", with: "\r\n")) == "y")  // as reg.exe writes it
        #expect(RetinaMode.queriedValue(in: "reg: Unable to find the specified registry key or value") == nil)
    }

    @Test func detectsARunningBottleByItsServerSocket() throws {
        try withTempDir { root in
            let prefix = try root.appending(path: "prefix").makeDirectory()
            let base = root.appending(path: "wine-uid")
            #expect(!WineServer.isRunning(prefix: prefix, base: base))
            let server = try WineServer.directory(forPrefix: prefix, base: base)
            try server.appending(path: "lock").write("")  // left behind after the server exits
            #expect(!WineServer.isRunning(prefix: prefix, base: base))
            try server.appending(path: "socket").write("")
            #expect(WineServer.isRunning(prefix: prefix, base: base))
        }
    }

    @Test func storesTheSettingWithWineReg() {
        #expect(RetinaMode.command(enabled: true)
                == ["reg", "add", #"HKCU\Software\Wine\Mac Driver"#, "/v", "RetinaMode", "/t", "REG_SZ", "/d", "y", "/f"])
        #expect(RetinaMode.command(enabled: false).suffix(3) == ["/d", "n", "/f"])
    }
}
