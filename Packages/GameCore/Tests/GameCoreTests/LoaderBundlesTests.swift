import Foundation
import Testing
@testable import GameCore

struct LoaderBundlesTests {
    private func makeBundle(_ name: String, in folder: URL, identifier: String) throws {
        let contents = folder.appending(path: "\(name).app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
    }

    /// Only our runtime's bundles in `winetemp-*` folders: other Wine builds keep theirs.
    @Test func findsOnlyOurBundles() throws {
        try withTempDir { temporary in
            let ours = temporary.appending(path: "winetemp-1-2-3-4", directoryHint: .isDirectory)
            try makeBundle("RDR2.exe", in: ours, identifier: LoaderBundles.identifier)
            try makeBundle("wine", in: ours, identifier: LoaderBundles.identifier)
            try makeBundle("Other.exe", in: ours, identifier: "com.codeweavers.CrossOver.wineloader")
            try makeBundle("Elsewhere", in: temporary.appending(path: "not-wine"), identifier: LoaderBundles.identifier)
            FileManager.default.createFile(atPath: ours.appending(path: "steam.exe").path, contents: Data())

            #expect(LoaderBundles.find(in: temporary).map(\.lastPathComponent) == ["RDR2.exe.app", "wine.app"])
            #expect(LoaderBundles.find(in: temporary.appending(path: "missing")).isEmpty)
        }
    }
}
