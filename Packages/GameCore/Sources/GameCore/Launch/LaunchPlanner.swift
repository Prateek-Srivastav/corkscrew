import Foundation

/// What every Wine command for a bottle needs.
public struct WineContext: Sendable {
    public var engine: Engine
    public var bottle: Bottle
    public var location: BottleLocation
    public var paths: AppPaths
    /// The app's own environment; only locale and user basics are passed on.
    public var hostEnvironment: [String: String]

    public init(engine: Engine, bottle: Bottle, location: BottleLocation, paths: AppPaths, hostEnvironment: [String: String]) {
        self.engine = engine
        self.bottle = bottle
        self.location = location
        self.paths = paths
        self.hostEnvironment = hostEnvironment
    }
}

public struct GameLaunch: Sendable {
    public var gameID: UUID
    public var executable: URL
    public var profile: GameProfile
    public var detectedAPIs: Set<GraphicsAPI>
    /// The game's CPU architecture; D3DMetal only exists for 64-bit games.
    public var machine: PEFile.Machine

    public init(
        gameID: UUID, executable: URL, profile: GameProfile, detectedAPIs: Set<GraphicsAPI>,
        machine: PEFile.Machine = .x86_64
    ) {
        self.gameID = gameID
        self.executable = executable
        self.profile = profile
        self.detectedAPIs = detectedAPIs
        self.machine = machine
    }
}

/// A fully resolved command, ready for `Process`.
public struct LaunchPlan: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL
    public var backend: GraphicsBackend?
    /// The Seatbelt profile passed inline to `sandbox-exec` (isolated bottles). Kept for the launch log.
    public var sandboxProfile: String?
    /// The backend the game's settings or detection asked for, when it isn't installed and
    /// `backend` stands in for it.
    public var unavailableBackend: GraphicsBackend? = nil
}

public enum LaunchError: Error, Equatable {
    /// Isolated bottles only see their own C: drive. Import the game into the bottle first.
    case executableOutsideIsolatedBottle(String)
}

public enum LaunchPlanner {
    static let sandboxExec = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    /// Host variables passed through to Wine. Everything else (API tokens, SSH_AUTH_SOCK, …) is dropped.
    static let passthroughKeys: Set<String> = [
        "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "__CF_USER_TEXT_ENCODING",
    ]

    /// Settings for MoltenVK (DXVK, and Vulkan through WineD3D), set on every game launch: games
    /// started from Steam's window inherit Steam's environment, whatever backend Steam runs on.
    /// Measured with `scripts/bench.sh` on an M4 (2026-10-10): asynchronous queue submits took
    /// DXVK from 36 to 45 FPS at 100,000 draws per frame (CPU-bound).
    static let performanceEnvironment = [
        // Encodes Metal commands on MoltenVK's own queue, not on the thread that submits.
        "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS": "0",
        // Lets Metal compile more shaders at once: shorter loading and compile stutter.
        "MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION": "1",
    ]

    /// Steam loads its overlay into every game it starts. In Red Dead Redemption 2 it wrapped the
    /// DXGI factory and swap chain, created its own D3D12 renderer, and hooked input and cursor
    /// calls (Steam's `logs/gameoverlay_renderer.txt`, 2026-10-09). Disabled DLLs can't be loaded,
    /// not even by full path, so the game talks to D3DMetal directly. Games inherit Steam's
    /// environment, so this goes on Steam's own launch too.
    static let steamOverlayOff = ["gameoverlayrenderer": "", "gameoverlayrenderer64": ""]

    public static func plan(_ game: GameLaunch, in context: WineContext) throws -> LaunchPlan {
        // A backend that isn't installed (D3DMetal in a build without the Game Porting Toolkit) would
        // leave the game on WineD3D's DLLs while Wine is told otherwise; use the best installed one.
        let available = ComponentCatalog.availableBackends(of: context.engine)
        let wanted = game.profile.backendOverride ?? .recommended(for: game.detectedAPIs, machine: game.machine)
        let backend = available.contains(wanted)
            ? wanted : .recommended(for: game.detectedAPIs, machine: game.machine, available: available)
        let isolated = context.bottle.kind == .isolated
        if isolated, !isInside(game.executable, context.location.prefix) {
            throw LaunchError.executableOutsideIsolatedBottle(game.executable.path)
        }

        var env = baseEnvironment(context, verboseLogging: game.profile.verboseLogging)
        if context.engine.architecture == .x86_64, game.profile.advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        if game.profile.metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        env.merge(performanceEnvironment) { _, tuned in tuned }
        let shaderCache = context.paths.shaderCache(for: game.gameID).path
        switch backend {
        case .d3dmetal:
            if game.profile.metalFX { env["D3DM_ENABLE_METALFX"] = "1" }
        case .dxmt:
            // DXMT's DLSS (nvngx) runs on MetalFX; it's only offered with the NVIDIA extension on.
            if game.profile.metalFX { env["DXMT_ENABLE_NVEXT"] = "1" }
            // Its default cache folder isn't writable in isolated bottles, which then compile every
            // shader again on each launch.
            env["DXMT_SHADER_CACHE_PATH"] = shaderCache
        case .dxvk:
            env["DXVK_STATE_CACHE_PATH"] = shaderCache
            env["DXVK_LOG_PATH"] = context.paths.logs(for: game.gameID).path
            // Compiles new pipelines in the background instead of stopping the frame (no stutter);
            // a new object can be missing for a frame or two.
            env["DXVK_ASYNC"] = "1"
        case .wined3d:
            break
        }
        env["WINEDLLPATH"] = dllPath(for: backend, engine: context.engine)
        // CrossOver's Wine reads this, e.g. to report GPU hardware scheduling under D3DMetal.
        env["CX_ACTIVE_GRAPHICS_BACKEND"] = backend.rawValue
        env.merge(context.engine.backendEnvironment[backend] ?? [:]) { _, engine in engine }
        var overrides = context.engine.backendDLLOverrides[backend] ?? [:]
        if !game.profile.steamOverlay { overrides.merge(steamOverlayOff) { engine, _ in engine } }
        env["WINEDLLOVERRIDES"] = dllOverrides(overrides)
        env.merge(game.profile.environment) { _, user in user }

        // Installer packages go through Windows Installer; everything else is started directly.
        let command = Launcher.isInstallerPackage(game.executable)
            ? ["msiexec", "/i", game.executable.path] : [game.executable.path]
        var plan = try wrap(
            arguments: command + game.profile.arguments,
            environment: env,
            workingDirectory: game.executable.deletingLastPathComponent(),
            backend: backend,
            extraWritable: [context.paths.shaderCache(for: game.gameID), context.paths.logs(for: game.gameID)],
            context: context
        )
        if backend != wanted { plan.unavailableBackend = wanted }
        return plan
    }

    /// Plans a Wine utility command (`wineboot`, `reg`, `msiexec`, …). Isolated bottles get the same
    /// sandbox: setup must never run outside it, or an unsandboxed wineserver would serve the bottle.
    public static func plan(
        wineArguments: [String], in context: WineContext, dllOverrides extra: [String: String] = [:]
    ) throws -> LaunchPlan {
        var env = baseEnvironment(context, verboseLogging: false)
        env["WINEDLLPATH"] = dllPath(for: .wined3d, engine: context.engine)
        env["WINEDLLOVERRIDES"] = dllOverrides(extra)
        return try wrap(
            arguments: wineArguments,
            environment: env,
            workingDirectory: context.location.prefix,
            backend: nil,
            extraWritable: [],
            context: context
        )
    }

    static func sandboxRules(for context: WineContext, extraWritable: [URL]) throws -> SandboxRules {
        SandboxRules(
            hiddenRoots: [URL(fileURLWithPath: "/Users"), URL(fileURLWithPath: "/Volumes"), context.paths.userHome],
            readOnly: context.engine.readOnlyRoots,
            readWrite: [context.location.prefix, context.location.home] + extraWritable,
            executableRoots: [context.engine.root],
            wineServerBase: context.paths.wineServerDirectory,
            wineServerDirectory: try WineServer.directory(
                forPrefix: context.location.prefix, base: context.paths.wineServerDirectory
            )
        )
    }

    private static func baseEnvironment(_ context: WineContext, verboseLogging: Bool) -> [String: String] {
        var env = context.hostEnvironment.filter { passthroughKeys.contains($0.key) }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["WINEPREFIX"] = context.location.prefix.path
        env["WINEMSYNC"] = "1"
        env["WINEDEBUG"] = verboseLogging ? "err+all,fixme-all,+loaddll" : "-all"
        if context.bottle.kind == .isolated {
            // Keeps Unix-side libraries (fontconfig, MoltenVK, …) out of your real home folder, and
            // temporary files in the bottle: nothing else is writable.
            env["HOME"] = context.location.home.path
            env["TMPDIR"] = context.location.home.path
            // Our Wine build otherwise re-runs itself through a game-named link in $TMPDIR (for the
            // Dock), which the sandbox rightly refuses to run.
            env["CORKSCREW_NO_LOADER_LINK"] = "1"
        }
        return env
    }

    private static func wrap(
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        backend: GraphicsBackend?,
        extraWritable: [URL],
        context: WineContext
    ) throws -> LaunchPlan {
        guard context.bottle.kind == .isolated else {
            return LaunchPlan(
                executable: context.engine.wine, arguments: arguments, environment: environment,
                workingDirectory: workingDirectory, backend: backend, sandboxProfile: nil
            )
        }
        let rules = try sandboxRules(for: context, extraWritable: extraWritable)
        let profile = try SandboxProfile.render(rules, policy: context.bottle.isolation)
        // Inline (-p) rather than a file, so nothing on disk can be edited to weaken the next launch.
        return LaunchPlan(
            executable: sandboxExec, arguments: ["-p", profile, context.engine.wine.path] + arguments,
            environment: environment, workingDirectory: workingDirectory, backend: backend, sandboxProfile: profile
        )
    }

    /// The backend's DLL folders, then Wine's own Direct3D DLLs as the fallback.
    private static func dllPath(for backend: GraphicsBackend, engine: Engine) -> String {
        var folders = engine.backendDLLPaths[backend] ?? []
        if !folders.contains(engine.wined3dDLLs) { folders.append(engine.wined3dDLLs) }
        return folders.map(\.path).joined(separator: ":")
    }

    /// `WINEDLLOVERRIDES`, sorted for stable logs. `winemenubuilder` is always off so Windows
    /// programs can't add Mac menu entries or file associations.
    private static func dllOverrides(_ overrides: [String: String]) -> String {
        var all = overrides
        all["winemenubuilder.exe"] = ""
        return all.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
    }

    private static func isInside(_ url: URL, _ root: URL) -> Bool {
        SandboxProfile.canonicalPath(url).hasPrefix(SandboxProfile.canonicalPath(root) + "/")
    }
}
