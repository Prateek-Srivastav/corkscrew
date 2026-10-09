import Foundation

/// Stages D3DMetal from the user's own Game Porting Toolkit download (never redistributed) as
/// `<components>/d3dmetal-<version>/{external,wine}`, the layout `ComponentCatalog` reads.
///
/// The toolkit image holds the "Evaluation environment for Windows games <version>" as a second,
/// nested image; its `redist/lib` is what Wine needs. Both images are mounted read-only.
public enum GPTKImporter {
    public enum ImportError: Error, Equatable, CustomStringConvertible {
        case attachFailed(String)
        case noEvaluationEnvironment
        case unknownVersion(String)
        case missingFiles(String)
        case alreadyImported(String)

        public var description: String {
            switch self {
            case .attachFailed(let image): "couldn't mount \(image)"
            case .noEvaluationEnvironment: "no \"Evaluation environment for Windows games\" image inside; is this a Game Porting Toolkit download?"
            case .unknownVersion(let name): "can't read a toolkit version from \"\(name)\""
            case .missingFiles(let what): "the toolkit is missing \(what)"
            case .alreadyImported(let folder): "\(folder) is already staged"
            }
        }
    }

    /// Imports the toolkit image at `dmg` and returns the staged folder.
    @discardableResult
    public static func importToolkit(dmg: URL, into components: URL) throws -> URL {
        let fm = FileManager.default
        let outer = try attach(dmg)
        defer { detach(outer) }
        let images = (try? fm.contentsOfDirectory(atPath: outer.path)) ?? []
        guard let innerName = images.first(where: { $0.hasPrefix("Evaluation environment") && $0.hasSuffix(".dmg") })
        else { throw ImportError.noEvaluationEnvironment }
        guard let version = version(fromImageName: innerName) else { throw ImportError.unknownVersion(innerName) }

        let destination = components.appending(path: "d3dmetal-\(version)", directoryHint: .isDirectory)
        guard !fm.fileExists(atPath: destination.path) else { throw ImportError.alreadyImported(destination.lastPathComponent) }

        let inner = try attach(outer.appending(path: innerName))
        defer { detach(inner) }
        let lib = inner.appending(path: "redist/lib", directoryHint: .isDirectory)
        for required in ["external/libd3dshared.dylib", "wine/x86_64-windows/d3d12.dll", "wine/x86_64-unix"]
        where !fm.fileExists(atPath: lib.appending(path: required).path) {
            throw ImportError.missingFiles(required)
        }

        // Stage beside the destination, then rename, so a failed import leaves nothing half-copied.
        try fm.createDirectory(at: components, withIntermediateDirectories: true)
        let staging = components.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: lib, to: staging)
        let license = inner.appending(path: "License.rtf")
        if fm.fileExists(atPath: license.path) { try fm.copyItem(at: license, to: staging.appending(path: "Apple-License.rtf")) }
        try fixUp(staging)
        try fm.moveItem(at: staging, to: destination)
        return destination
    }

    /// "Evaluation environment for Windows games 4.0 beta 2.dmg" → "4.0b2"; "… 3.0.dmg" → "3.0".
    static func version(fromImageName name: String) -> String? {
        guard let match = name.firstMatch(of: /(\d+(?:\.\d+)+)(?:\s*beta\s*(\d+))?\.dmg$/) else { return nil }
        return String(match.1) + (match.2.map { "b\($0)" } ?? "")
    }

    /// Wine's side looks for `nvngx`, which GPTK ships as `nvngx-on-metalfx`; the Unix-side modules
    /// find `libd3dshared` through `@loader_path`, i.e. their own folder.
    static func fixUp(_ lib: URL) throws {
        let fm = FileManager.default
        for (folder, ext) in [("wine/x86_64-windows", "dll"), ("wine/x86_64-unix", "so")] {
            let from = lib.appending(path: "\(folder)/nvngx-on-metalfx.\(ext)")
            let to = lib.appending(path: "\(folder)/nvngx.\(ext)")
            if fm.fileExists(atPath: from.path) || (try? fm.destinationOfSymbolicLink(atPath: from.path)) != nil {
                try? fm.removeItem(at: to)
                try fm.moveItem(at: from, to: to)
            }
        }
        let link = lib.appending(path: "wine/x86_64-unix/libd3dshared.dylib")
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil, !fm.fileExists(atPath: link.path) {
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../../external/libd3dshared.dylib")
        }
    }

    private static func attach(_ image: URL) throws -> URL {
        let mountPoint = FileManager.default.temporaryDirectory.appending(path: "gptk-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let status = hdiutil(["attach", "-quiet", "-readonly", "-nobrowse", "-noverify", "-mountpoint", mountPoint.path, image.path])
        guard status == 0 else {
            try? FileManager.default.removeItem(at: mountPoint)
            throw ImportError.attachFailed(image.lastPathComponent)
        }
        return mountPoint
    }

    private static func detach(_ mountPoint: URL) {
        if hdiutil(["detach", "-quiet", mountPoint.path]) != 0 { _ = hdiutil(["detach", "-quiet", "-force", mountPoint.path]) }
        try? FileManager.default.removeItem(at: mountPoint)
    }

    @discardableResult
    private static func hdiutil(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
