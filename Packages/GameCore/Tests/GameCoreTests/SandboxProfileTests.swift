import Foundation
import Testing
@testable import GameCore

struct SandboxProfileTests {
    private func rules(_ root: URL) -> SandboxRules {
        let home = root.appending(path: "home")
        return SandboxRules(
            hiddenRoots: [home],
            readOnly: [home.appending(path: "runtime"), home.appending(path: "components")],
            readWrite: [home.appending(path: "bottle/prefix"), home.appending(path: "bottle/home")],
            executableRoots: [home.appending(path: "runtime")],
            wineServerBase: root.appending(path: "wine-base"),
            wineServerDirectory: root.appending(path: "wine-base/server-1-2")
        )
    }

    @Test func hidesFirstThenReallowsTheBottle() throws {
        let profile = try SandboxProfile.render(rules(URL(fileURLWithPath: "/private/tmp/cg")), policy: IsolationPolicy())
        let hide = try #require(profile.range(of: "(deny file-read* file-write*"))
        let reallow = try #require(profile.range(of: "(allow file-read* file-write*"))
        #expect(hide.lowerBound < reallow.lowerBound)
        #expect(profile.contains(#"(subpath "/private/tmp/cg/home/bottle/prefix")"#))
        #expect(profile.contains("(deny process-exec*)"))
        // Writes are denied everywhere first, then re-allowed only for the bottle.
        let noWrites = try #require(profile.range(of: "(deny file-write*)\n"))
        #expect(noWrites.lowerBound < reallow.lowerBound)
        // Apps and launchd jobs started for the program would run outside the sandbox.
        #expect(profile.contains("(deny lsopen)"))
        #expect(profile.contains("(deny job-creation)"))
        #expect(profile.contains("(deny network* (remote ip))"))
        #expect(profile.contains("com.apple.pasteboard.1"))
        #expect(!profile.contains("mDNSResponder"))
    }

    @Test func networkAndClipboardCanBeAllowedPerBottle() throws {
        let profile = try SandboxProfile.render(
            rules(URL(fileURLWithPath: "/private/tmp/cg")),
            policy: IsolationPolicy(allowNetwork: true, allowClipboard: true)
        )
        #expect(!profile.contains("(deny network* (remote ip))"))
        #expect(profile.contains("mDNSResponder"))
        #expect(!profile.contains("com.apple.pasteboard.1"))
    }

    @Test func escapesQuotesAndBackslashes() throws {
        var unusual = rules(URL(fileURLWithPath: "/private/tmp/cg"))
        unusual.readOnly = [URL(fileURLWithPath: "/private/tmp/a \"quoted\" \\dir")]
        let profile = try SandboxProfile.render(unusual, policy: IsolationPolicy())
        #expect(profile.contains(#"(subpath "/private/tmp/a \"quoted\" \\dir")"#))
    }

    @Test func refusesUnsafeInput() {
        var newline = rules(URL(fileURLWithPath: "/private/tmp/cg"))
        newline.readWrite = [URL(fileURLWithPath: "/private/tmp/evil\n(allow default)")]
        #expect(throws: SandboxProfile.RenderError.self) { try SandboxProfile.render(newline, policy: IsolationPolicy()) }

        var nothingHidden = rules(URL(fileURLWithPath: "/private/tmp/cg"))
        nothingHidden.hiddenRoots = []
        #expect(throws: SandboxProfile.RenderError.missingRules("hiddenRoots")) {
            try SandboxProfile.render(nothingHidden, policy: IsolationPolicy())
        }
    }

    @Test func canonicalPathResolvesSymlinkedAncestors() {
        #expect(SandboxProfile.canonicalPath(URL(fileURLWithPath: "/tmp/cg-not-there/x")) == "/private/tmp/cg-not-there/x")
    }

    /// Runs the real macOS sandbox with copies of /bin/cat and /usr/bin/touch standing in for Wine.
    @Test func macOSSandboxEnforcesTheProfile() throws {
        try withTempDir { root in
            let fm = FileManager.default
            let home = root.appending(path: "home")
            let bin = try home.appending(path: "runtime/bin").makeDirectory()
            let cat = bin.appending(path: "cat").path
            let touch = bin.appending(path: "touch").path
            // macOS kills copies of its own system binaries, so re-sign the copies ad hoc.
            let realpath = bin.appending(path: "realpath").path
            let ls = bin.appending(path: "ls").path
            for (source, copy) in [("/bin/cat", cat), ("/usr/bin/touch", touch), ("/bin/realpath", realpath), ("/bin/ls", ls)] {
                try fm.copyItem(atPath: source, toPath: copy)
                #expect(try run("/usr/bin/codesign", "--force", "--sign", "-", copy).status == 0)
            }
            try home.appending(path: "secret.txt").write("secret")
            let save = home.appending(path: "bottle/prefix/drive_c/save.txt")
            try save.write("save")
            let metadata = home.appending(path: "bottle/bottle.json")
            try metadata.write("{}")
            try root.appending(path: "wine-base/server-1-2").makeDirectory()
            try root.appending(path: "wine-base/server-9-9").makeDirectory()
            let profile = try SandboxProfile.render(rules(root), policy: IsolationPolicy())

            // Controls: without the sandbox every operation below succeeds, so each denial is the sandbox's doing.
            #expect(try run(cat, home.appending(path: "secret.txt").path) == Result(status: 0, output: "secret"))
            #expect(try run(touch, metadata.path).status == 0)

            #expect(try sandboxed(profile, cat, save.path) == Result(status: 0, output: "save"))
            #expect(try sandboxed(profile, cat, home.appending(path: "secret.txt").path).status != 0)
            #expect(try sandboxed(profile, touch, home.appending(path: "bottle/prefix/new.txt").path).status == 0)
            // The bottle's own settings stay out of reach, so a program can't switch off its isolation.
            #expect(try sandboxed(profile, touch, metadata.path).status != 0)
            // Resolving a path inside the bottle works (needs metadata on parents such as /Users)…
            #expect(try sandboxed(profile, realpath, save.path).status == 0)
            // …but the hidden folders still can't be listed.
            #expect(try run(ls, home.path).status == 0)
            #expect(try sandboxed(profile, ls, home.path).status != 0)
            // Programs outside the runtime can't be started.
            #expect(try sandboxed(profile, "/bin/cat", save.path).status != 0)
            // Nothing outside the bottle is writable, even outside the hidden folders: no programs
            // planted in /Applications or /opt/homebrew for you to run later.
            #expect(try run(touch, root.appending(path: "outside.txt").path).status == 0)
            #expect(try sandboxed(profile, touch, root.appending(path: "planted.txt").path).status != 0)
            // The runtime stays read-only, so its "may start programs" rule can't be abused.
            #expect(try sandboxed(profile, touch, bin.appending(path: "planted").path).status != 0)
            // The hidden folders stay hidden under their other spelling (APFS firmlinks).
            let firmlinked = "/System/Volumes/Data" + SandboxProfile.canonicalPath(home.appending(path: "secret.txt"))
            #expect(try run(cat, firmlinked) == Result(status: 0, output: "secret"))
            #expect(try sandboxed(profile, cat, firmlinked).status != 0)
            // Only this bottle's wineserver folder is writable; no fake sockets for other bottles.
            #expect(try sandboxed(profile, touch, root.appending(path: "wine-base/server-1-2/socket").path).status == 0)
            #expect(try sandboxed(profile, touch, root.appending(path: "wine-base/server-9-9/socket").path).status != 0)
        }
    }

    struct Result: Equatable {
        var status: Int32
        var output: String
    }

    private func sandboxed(_ profile: String, _ tool: String, _ arguments: String...) throws -> Result {
        try run("/usr/bin/sandbox-exec", ["-p", profile, tool] + arguments)
    }

    private func run(_ tool: String, _ arguments: String...) throws -> Result {
        try run(tool, arguments)
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Result(status: process.terminationStatus, output: output)
    }
}
