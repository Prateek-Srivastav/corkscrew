import Foundation

/// Locates a prefix's wineserver folder, mirroring Wine's `init_server_dir`
/// (dlls/ntdll/unix/server.c): `/tmp/.wine-<uid>/server-<dev hex>-<inode hex>` of the prefix.
public enum WineServer {
    public enum LocateError: Error, Equatable {
        case prefixMissing(String)
    }

    /// The prefix must exist; create it before running `wineboot` on a new bottle.
    public static func directory(forPrefix prefix: URL, base: URL) throws -> URL {
        var info = stat()
        guard stat(prefix.path, &info) == 0 else { throw LocateError.prefixMissing(prefix.path) }
        // Wine prints `(unsigned long long)dev`, which sign-extends the 32-bit dev_t.
        let dev = String(UInt(bitPattern: Int(info.st_dev)), radix: 16)
        let ino = String(info.st_ino, radix: 16)
        return base.appending(path: "server-\(dev)-\(ino)", directoryHint: .isDirectory)
    }

    /// Whether the prefix's wineserver is up. It removes its socket as it starts shutting down, before
    /// saving the registry, so use `ProcessRunner.waitForSession` before trusting files in the prefix.
    public static func isRunning(prefix: URL, base: URL) -> Bool {
        guard let server = try? directory(forPrefix: prefix, base: base) else { return false }
        return FileManager.default.fileExists(atPath: server.appending(path: "socket").path)
    }
}
