import Foundation

/// The Rockstar Games Launcher (RDR2, GTA V, …), which Rockstar games start before the game itself.
///
/// It draws its window with Direct2D, and Wine's Direct2D needs Wine's own Direct3D 10/11 and DXGI.
/// Games started from Steam inherit Steam's backend, so under D3DMetal the launcher gets D3DMetal's
/// `dxgi`/`d3d11`/`d3d12`, Direct2D can't create a device, and the launcher stops with "failed to
/// initialize". Wine's Vulkan renderer can't help either: MoltenVK has no geometry shaders, so it
/// can't create the Direct3D 10.1 device Direct2D asks for; OpenGL can.
///
/// So the launcher's two programs get Wine's own Direct3D DLLs, rendering through OpenGL, while the
/// game keeps its backend:
/// - Wine's DLLs are copied into `system32` as plain DLLs (without the "Wine builtin DLL" mark).
///   With the default load order Wine still prefers the builtin (the backend's DLL, from
///   `WINEDLLPATH`) for every other program.
/// - `AppDefaults\Launcher.exe\DllOverrides` (and `SocialClubHelper.exe`) load those copies
///   instead ("native"), and `AppDefaults\…\Direct3D` picks the OpenGL renderer. The launcher only
///   searches `system32` for DLLs, so copies next to it would be ignored.
/// - D3DMetal's GPU vendor libraries are turned off for them: once signed in, the launcher asks
///   `nvapi64` about the GPU, and D3DMetal's version crashes without D3DMetal's `dxgi`.
/// - `SocialClubHelper.exe` (Chromium, which draws the launcher's pages and prompts) gets no
///   Direct3D 11/12: its Direct3D 11 path crashes under Wine, and it draws in software anyway.
///   Chromium draws from its GPU process into the browser process's windows, which winemac can't
///   show (another process's drawing is dropped), so every page stayed white; the runtime's
///   kernelbase patch (scripts/build-runtime.sh) starts it with `--in-process-gpu`.
/// - Red Dead Redemption 2 runs on DirectX 12: it picks its API from its settings, and Vulkan would
///   go through Wine's Vulkan to MoltenVK instead of D3DMetal. Its window gets the desktop's size
///   (`fitWindow`): in Windowed Borderless always, in fullscreen on the first launch.
public enum RockstarLauncher {
    static let programs = ["Launcher.exe", "SocialClubHelper.exe"]
    static let dlls = ["dxgi", "d3d10", "d3d11", "d3d12", "d3d12core"]
    /// D3DMetal's stand-ins for NVIDIA's and AMD's driver libraries.
    static let disabledDLLs = ["nvapi64", "nvngx", "atidxx64"]

    /// The program's `DllOverrides`: "native" loads the copies in system32, "" turns a DLL off.
    static func overrides(for program: String) -> [(dll: String, order: String)] {
        let off = program == "SocialClubHelper.exe" ? disabledDLLs + ["d3d11", "d3d12", "d3d12core"] : disabledDLLs
        return dlls.filter { !off.contains($0) }.map { ($0, "native") } + off.map { ($0, "") }
    }

    /// Whether the bottle has the launcher, or a Steam game there installs it on its first launch
    /// (its `Redistributables/Rockstar-Games-Launcher.exe`).
    public static func isNeeded(prefix: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: prefix.appending(path: "drive_c/Program Files/Rockstar Games/Launcher/Launcher.exe").path) {
            return true
        }
        guard let steam = Steam.root(inPrefix: prefix) else { return false }
        return Steam.installedApps(steamRoot: steam, prefix: prefix).contains {
            fm.fileExists(atPath: $0.installFolder.appending(path: "Redistributables/Rockstar-Games-Launcher.exe").path)
        }
    }

    /// Puts Wine's own Direct3D DLLs into the bottle's `system32` as plain DLLs. Runs before every
    /// launch: updating the bottle (`wineboot --update`) puts Wine's builtin copies back. Returns
    /// whether it changed anything.
    @discardableResult
    public static func installDLLs(prefix: URL, engine: Engine) throws -> Bool {
        let source = engine.wined3dDLLs.appending(path: "x86_64-windows", directoryHint: .isDirectory)
        let system32 = prefix.appending(path: "drive_c/windows/system32", directoryHint: .isDirectory)
        var changed = false
        for dll in dlls {
            let target = system32.appending(path: "\(dll).dll")
            let data = try plainDLL(Data(contentsOf: source.appending(path: "\(dll).dll")))
            if (try? Data(contentsOf: target)) == data { continue }
            try data.write(to: target, options: .atomic)
            changed = true
        }
        return changed
    }

    /// Wine marks its builtin DLLs with "Wine builtin DLL" right after the DOS header; without the
    /// mark the loader treats the file like any Windows DLL.
    static func plainDLL(_ data: Data) throws -> Data {
        let mark = Data("Wine builtin DLL".utf8)
        guard data.count >= 0x40 + mark.count else { throw CocoaError(.fileReadCorruptFile) }
        var plain = data
        let range = plain.startIndex + 0x40 ..< plain.startIndex + 0x40 + mark.count
        if plain[range] == mark { plain.replaceSubrange(range, with: Data(count: mark.count)) }
        return plain
    }

    /// The registry settings, as a `regedit` file.
    static var registryFile: String {
        var lines = ["Windows Registry Editor Version 5.00", ""]
        for program in programs {
            lines.append(#"[HKEY_CURRENT_USER\Software\Wine\AppDefaults\\#(program)\DllOverrides]"#)
            lines += overrides(for: program).map { #""\#($0.dll)"="\#($0.order)""# }
            lines += ["", #"[HKEY_CURRENT_USER\Software\Wine\AppDefaults\\#(program)\Direct3D]"#, #""renderer"="gl""#, ""]
        }
        return lines.joined(separator: "\r\n")
    }

    /// Whether the saved registry already has the settings (it can lag a running bottle by a few
    /// seconds; writing them again is harmless).
    static func isRegistrySet(prefix: URL) -> Bool {
        let file = prefix.appending(path: "user.reg")
        return programs.allSatisfy { program in
            let key = #"Software\Wine\AppDefaults\\#(program)"#
            return WineRegistry.value("renderer", inKey: key + #"\Direct3D"#, file: file) == "gl"
                && overrides(for: program).allSatisfy { WineRegistry.value($0.dll, inKey: key + #"\DllOverrides"#, file: file) == $0.order }
        }
    }

    /// Logged by the runtime's kernelbase patch for Social Club (scripts/build-runtime.sh); a runtime
    /// built before it shows the launcher's pages white.
    static let socialClubPatchMarker = "Social Club browser process"

    static func hasSocialClubPatch(engine: Engine) -> Bool {
        let kernelbase = engine.root.appending(path: "lib/wine/x86_64-windows/kernelbase.dll")
        guard let data = try? Data(contentsOf: kernelbase, options: .mappedIfSafe) else { return false }
        return data.range(of: Data(socialClubPatchMarker.utf8)) != nil
    }

    static let rdr2AppID = "1174180"
    static let dx12 = "kSettingAPI_DX12"

    static func rdr2Settings(prefix: URL) -> URL {
        prefix.appending(path: "drive_c/users/crossover/Documents/Rockstar Games/Red Dead Redemption 2/Settings/system.xml")
    }

    /// Whether Red Dead Redemption 2 is installed, from Steam or the Rockstar Games Launcher.
    static func hasRDR2(prefix: URL) -> Bool {
        if FileManager.default.fileExists(atPath: prefix.appending(
            path: "drive_c/Program Files/Rockstar Games/Red Dead Redemption 2/RDR2.exe").path) {
            return true
        }
        guard let steam = Steam.root(inPrefix: prefix) else { return false }
        return Steam.installedApps(steamRoot: steam, prefix: prefix).contains { $0.appID == rdr2AppID }
    }

    /// Sets RDR2's graphics API to DirectX 12 (also undoing a switch to Vulkan in the game's menu).
    /// Before the first launch there are no settings yet; it writes the tested ones
    /// (`rdr2TestedSettings`), which use DirectX 12. Returns whether it changed anything.
    @discardableResult
    static func ensureDX12(prefix: URL) throws -> Bool {
        let file = rdr2Settings(prefix: prefix)
        let wanted = "<API>\(dx12)</API>"
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            guard let range = text.range(of: "<API>[^<]*</API>", options: .regularExpression), text[range] != wanted else {
                return false
            }
            try text.replacingCharacters(in: range, with: wanted).write(to: file, atomically: true, encoding: .utf8)
            return true
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rdr2TestedSettings.write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    /// RDR2's screen types (`<windowed value="…" />`).
    static let fullscreen = "0"
    static let borderless = "2"

    /// In Windowed Borderless, RDR2 makes its window the size of its resolution setting, and its
    /// defaults (and Safe Mode) pick one smaller than the desktop: 1147×745 on a 1512×982 MacBook,
    /// a small window mid-screen. Sets a borderless window's resolution to the desktop's (also
    /// after moving between displays). With `anyScreenType`, also a fullscreen or windowed one: for
    /// the tested settings on their first launch, which were made on another Mac's desktop. Returns
    /// whether it changed anything.
    @discardableResult
    static func fitWindow(prefix: URL, desktop: (width: Int, height: Int), anyScreenType: Bool = false) throws -> Bool {
        let file = rdr2Settings(prefix: prefix)
        guard var text = try? String(contentsOf: file, encoding: .utf8),
              anyScreenType || settingValue("windowed", in: text) == borderless else { return false }
        let wanted = ["screenWidth": desktop.width, "screenHeight": desktop.height,
                      "screenWidthWindowed": desktop.width, "screenHeightWindowed": desktop.height]
        var changed = false
        for (name, value) in wanted.sorted(by: { $0.key < $1.key }) where settingValue(name, in: text) != String(value) {
            guard let range = text.range(of: "<\(name) value=\"[^\"]*\" />", options: .regularExpression) else { continue }
            text.replaceSubrange(range, with: "<\(name) value=\"\(value)\" />")
            changed = true
        }
        if changed { try text.write(to: file, atomically: true, encoding: .utf8) }
        return changed
    }

    /// A `<name value="…" />` setting.
    static func settingValue(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: "<\(name) value=\"[^\"]*\"", options: .regularExpression) else { return nil }
        return text[range].split(separator: "\"").last.map(String.init)
    }

    /// Makes the bottle ready for the launcher: the DLLs, the registry settings when missing, and
    /// DirectX 12 for RDR2. Returns notes for the user.
    public static func apply(in context: WineContext, log: URL) async throws -> [String] {
        let prefix = context.location.prefix
        var notes: [String] = []
        if !hasSocialClubPatch(engine: context.engine) {
            notes.append("This Wine runtime was built before the Social Club fix, so the Rockstar Games Launcher's pages "
                         + "stay white. Rebuild it with scripts/build-runtime.sh.")
        }
        if hasRDR2(prefix: prefix) {
            let isFirstLaunch = !FileManager.default.fileExists(atPath: rdr2Settings(prefix: prefix).path)
            if try ensureDX12(prefix: prefix) {
                notes.append(isFirstLaunch
                    ? "Gave Red Dead Redemption 2 the tested graphics settings (DirectX 12 on D3DMetal, with MetalFX)."
                    : "Set Red Dead Redemption 2 to DirectX 12, which runs on D3DMetal (Vulkan doesn't work here).")
            }
        }
        try installDLLs(prefix: prefix, engine: context.engine)
        guard !isRegistrySet(prefix: prefix) else { return notes }
        let file = prefix.appending(path: "drive_c/windows/temp/corkscrew-rockstar.reg")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try registryFile.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let plan = try LaunchPlanner.plan(wineArguments: ["regedit", "/S", #"C:\windows\temp\corkscrew-rockstar.reg"#], in: context)
        let result = try await ProcessRunner.run(plan, log: log, wineserver: context.engine.wineserver)
        guard result.status == 0 else { throw Error.registryFailed(status: result.status, log: log.path) }
        return notes
    }

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case registryFailed(status: Int32, log: String)
        public var description: String {
            switch self {
            case .registryFailed(let status, let log):
                "couldn't set up the Rockstar Games Launcher (regedit exited \(status)); see \(log)"
            }
        }
    }
}
