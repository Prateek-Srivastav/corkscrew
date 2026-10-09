import Foundation
import Testing
@testable import GameCore

struct PrefixHardeningTests {
    @Test func cutsLinksToTheMacAndIsIdempotent() throws {
        try withTempDir { root in
            let fm = FileManager.default
            let prefix = root.appending(path: "prefix", directoryHint: .isDirectory)
            let dosdevices = try prefix.appending(path: "dosdevices").makeDirectory()
            try prefix.appending(path: "drive_c").makeDirectory()
            try fm.createSymbolicLink(atPath: dosdevices.appending(path: "c:").path, withDestinationPath: "../drive_c")
            try fm.createSymbolicLink(atPath: dosdevices.appending(path: "z:").path, withDestinationPath: "/")
            try fm.createSymbolicLink(atPath: dosdevices.appending(path: "d:").path, withDestinationPath: "/Volumes/External")

            let macHome = root.appending(path: "mac-home")
            try macHome.appending(path: "Documents/keep.txt").write("mine")
            try macHome.appending(path: "Downloads").makeDirectory()
            let user = try prefix.appending(path: "drive_c/users/me").makeDirectory()
            for folder in ["Documents", "Downloads"] {
                try fm.createSymbolicLink(
                    atPath: user.appending(path: folder).path,
                    withDestinationPath: macHome.appending(path: folder).path
                )
            }
            try user.appending(path: "AppData").makeDirectory()

            let changes = try PrefixHardening.apply(prefix: prefix)
            #expect(changes.count == 4)
            #expect(try fm.destinationOfSymbolicLink(atPath: dosdevices.appending(path: "c:").path) == "../drive_c")
            #expect((try? fm.destinationOfSymbolicLink(atPath: dosdevices.appending(path: "z:").path)) == nil)
            #expect((try? fm.destinationOfSymbolicLink(atPath: dosdevices.appending(path: "d:").path)) == nil)

            let documents = user.appending(path: "Documents").path
            #expect((try? fm.destinationOfSymbolicLink(atPath: documents)) == nil)
            #expect(try fm.contentsOfDirectory(atPath: documents).isEmpty)
            #expect(fm.fileExists(atPath: user.appending(path: "AppData").path))
            #expect(fm.fileExists(atPath: macHome.appending(path: "Documents/keep.txt").path), "Mac files must be untouched")

            #expect(try PrefixHardening.apply(prefix: prefix).isEmpty)
        }
    }
}
