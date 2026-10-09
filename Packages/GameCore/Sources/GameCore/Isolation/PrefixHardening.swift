import Foundation

/// Cuts a Wine prefix's links to the Mac file system, like winetricks' `sandbox` verb.
///
/// Defense in depth only: the macOS sandbox is the real boundary. Run before every isolated
/// launch, because Wine can recreate these links when it updates a prefix.
public enum PrefixHardening {
    /// Folders Wine links to the Mac user's home folder.
    static let shellFolders: Set<String> = [
        "Desktop", "Documents", "Downloads", "Music", "Pictures", "Videos", "Templates",
        "My Documents", "My Music", "My Pictures", "My Videos",
    ]

    /// Returns a description of each change made; empty when the prefix was already hardened.
    @discardableResult
    public static func apply(prefix: URL) throws -> [String] {
        let fm = FileManager.default
        var changes: [String] = []
        let prefixPath = SandboxProfile.canonicalPath(prefix)

        // Drive letters that point outside the prefix (Z: → /, D: → /Volumes/…).
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        for entry in (try? fm.contentsOfDirectory(atPath: dosdevices.path)) ?? [] {
            let link = dosdevices.appending(path: entry)
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) else { continue }
            let target = SandboxProfile.canonicalPath(URL(fileURLWithPath: destination, relativeTo: dosdevices))
            guard target != prefixPath, !target.hasPrefix(prefixPath + "/") else { continue }
            try fm.removeItem(at: link)
            changes.append("Removed drive \(entry) → \(destination)")
        }

        // Desktop, Documents, … that Wine linked to the Mac user's folders.
        let users = prefix.appending(path: "drive_c/users", directoryHint: .isDirectory)
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
            let profile = users.appending(path: user, directoryHint: .isDirectory)
            for folder in (try? fm.contentsOfDirectory(atPath: profile.path)) ?? [] where shellFolders.contains(folder) {
                let link = profile.appending(path: folder)
                guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) else { continue }
                try fm.removeItem(at: link)
                try fm.createDirectory(at: link, withIntermediateDirectories: false)
                changes.append("Unlinked \(user)/\(folder) from \(destination)")
            }
        }
        return changes
    }
}
