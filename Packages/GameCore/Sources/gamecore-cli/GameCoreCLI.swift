import ArgumentParser
import Foundation
import GameCore

/// Drives GameCore from the terminal, for development and scripted smoke tests.
/// Defaults point at the repo's build/ folder, so nothing touches the app's real data.
@main
struct GameCoreCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gamecore-cli",
        abstract: "Create bottles and run Windows programs with the Corkscrew core.",
        subcommands: [BottleCommand.self, Run.self, Inspect.self, RuntimeCommand.self, ComponentsCommand.self]
    )
}

struct Environment: ParsableArguments {
    @Option(help: "Wine runtime folder.")
    var runtime = "build/runtime/winecx-26.3.0"
    @Option(help: "Graphics components folder.")
    var components = "build/components"
    @Option(help: "Where bottles, logs and caches go.")
    var data = "build/dev-data"
    @Option(help: "Game Porting Toolkit version for D3DMetal, e.g. 3.0 or 4.0b2. Default: the newest stable one staged.")
    var d3dmetal: String?
    @Option(help: "The Steam web helper wrapper (scripts/steam-fix.sh builds it); reapplied before Steam starts.")
    var steamWrapper = "build/tools/steamwebhelper-wrapper.exe"

    var steamWebHelperWrapper: URL? {
        let url = URL(fileURLWithPath: steamWrapper).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var paths: AppPaths { .rooted(at: URL(fileURLWithPath: data, isDirectory: true).standardizedFileURL) }

    var engine: Engine {
        get throws {
            try ComponentCatalog.engine(
                id: "winecx-26.3.0-x86_64",
                root: URL(fileURLWithPath: runtime, isDirectory: true).standardizedFileURL,
                architecture: .x86_64,
                components: URL(fileURLWithPath: components, isDirectory: true).standardizedFileURL,
                d3dmetalVersion: d3dmetal
            )
        }
    }

    func bottle(named name: String) throws -> Bottle {
        guard let bottle = try BottleStore(paths: paths).list().first(where: { $0.name == name }) else {
            throw ValidationError("No bottle named \"\(name)\". Create it with: gamecore-cli bottle create \(name)")
        }
        return bottle
    }
}

struct BottleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bottle", abstract: "Manage bottles.", subcommands: [Create.self, List.self, Reset.self]
    )

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a bottle.")
        @OptionGroup var env: Environment
        @Argument var name: String
        @Flag(help: "Run everything in this bottle inside the macOS sandbox.") var isolated = false
        @Flag(help: "Isolated bottles only: allow internet access.") var allowNetwork = false

        func run() async throws {
            let engine = try env.engine
            let bottle = Bottle(
                name: name, kind: isolated ? .isolated : .standard, engineID: engine.id,
                isolation: IsolationPolicy(allowNetwork: allowNetwork)
            )
            print("Creating \(bottle.kind.rawValue) bottle \"\(name)\"…")
            let store = BottleStore(paths: env.paths)
            try await store.create(bottle, engine: engine)
            print("Created \(store.location(of: bottle).prefix.path)")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List bottles.")
        @OptionGroup var env: Environment

        func run() throws {
            let store = BottleStore(paths: env.paths)
            for bottle in try store.list() {
                let network = bottle.kind == .isolated ? (bottle.isolation.allowNetwork ? " (internet on)" : " (offline)") : ""
                print("\(bottle.name)\t\(bottle.kind.rawValue)\(network)\t\(store.location(of: bottle).prefix.path)")
            }
        }
    }

    struct Reset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Restore an isolated bottle to its clean snapshot.")
        @OptionGroup var env: Environment
        @Argument var name: String

        func run() throws {
            try BottleStore(paths: env.paths).resetToClean(try env.bottle(named: name), engine: try env.engine)
            print("Reset \"\(name)\" to its clean state.")
        }
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a Windows program in a bottle.")
    @OptionGroup var env: Environment
    @Option(help: "Bottle name.") var bottle: String
    @Option(help: "Graphics backend: d3dmetal, dxmt, dxvk, wined3d. Default: picked from the program.")
    var backend: GraphicsBackend?
    @Flag(help: "Show Apple's Metal performance HUD (FPS, frame and GPU time, memory).") var hud = false
    @Flag(help: "Show the CPU / RAM / GPU overlay while the program runs.") var overlay = false
    @Flag(help: "Include Wine's error output in the launch log.") var verbose = false
    @Option(name: .customLong("env"), help: "Extra environment variable, KEY=VALUE (repeatable).")
    var environment: [String] = []
    @Flag(help: "D3DMetal only: offer MetalFX upscaling through the game's DLSS option.") var metalfx = false
    @Flag(help: "Retina mode: the game sees the display's full pixel resolution (sharper, much more GPU work). Off by default; applies to the whole bottle from this launch on.")
    var retina = false
    @Argument(help: "The .exe to run.") var executable: String
    @Argument(parsing: .captureForPassthrough, help: "Arguments for the program.") var arguments: [String] = []

    func run() async throws {
        let exe = URL(fileURLWithPath: executable).standardizedFileURL
        let target = try env.bottle(named: bottle)
        let engine = try env.engine
        var extra: [String: String] = [:]
        for pair in environment {
            guard let equals = pair.firstIndex(of: "=") else { throw ValidationError("--env expects KEY=VALUE, got \(pair)") }
            extra[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        // Passthrough capture keeps the "--" separator; the program must not see it (Steam ignores every
        // flag after one, so -noverifyfiles stopped working and Steam restored its web helper).
        let programArguments = arguments.first == "--" ? Array(arguments.dropFirst()) : arguments
        let profile = GameProfile(backendOverride: backend, metalFX: metalfx, retinaMode: retina, metalHUD: hud,
                                  performanceOverlay: overlay, verboseLogging: verbose, arguments: programArguments,
                                  environment: extra)
        let prepared = try await Launcher.prepare(gameID: UUID(), executable: exe, profile: profile, bottle: target,
                                                  engine: engine, paths: env.paths, steamWebHelperWrapper: env.steamWebHelperWrapper)
        for finding in prepared.inspection?.antiCheat ?? [] {
            print("warning: \(finding.kind.rawValue) found (\(finding.evidence)): "
                  + (finding.severity == .blocksLaunch ? "this game won't run under Wine." : "online play may not work."))
        }
        prepared.notes.forEach { print($0) }
        print("Running \(exe.lastPathComponent) with \(prepared.plan.backend?.displayName ?? "-")"
              + (target.kind == .isolated ? " in the sandbox" : "") + " (log: \(prepared.log.path))")
        if overlay { try startOverlay(prefix: prepared.context.location.prefix) }
        let result = try await Launcher.run(prepared)
        throw ExitCode(result.status)
    }

    /// perf-overlay is built next to this tool; it exits by itself when the bottle goes idle.
    private func startOverlay(prefix: URL) throws {
        let tool = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "perf-overlay")
        let overlay = Process()
        overlay.executableURL = tool
        overlay.arguments = [prefix.path]
        try overlay.run()
    }
}

struct RuntimeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runtime", abstract: "Manage installed Wine runtimes.", subcommands: [List.self, Install.self, Import.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List installed runtimes.")
        @OptionGroup var env: Environment

        func run() {
            let store = RuntimeStore(paths: env.paths)
            for manifest in store.list() {
                let root = store.location(of: manifest.id)
                print("\(manifest.id)\t\(manifest.architecture.rawValue)\tmodules \(RuntimeModules.fingerprint(runtime: root))\t\(root.path)")
            }
        }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Install a runtime archive after checking its SHA-256.")
        @OptionGroup var env: Environment
        @Argument(help: "The runtime archive (.tar.xz, .tar.gz, …).") var archive: String
        @Option(help: "The archive's expected SHA-256.") var sha256: String

        func run() throws {
            let manifest = try RuntimeStore(paths: env.paths).install(archive: URL(fileURLWithPath: archive), sha256: sha256)
            print("Installed \(manifest.id)")
        }
    }

    struct Import: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Install a runtime folder built on this Mac (APFS clone).")
        @OptionGroup var env: Environment
        @Argument(help: "The runtime folder, e.g. build/runtime/winecx-26.3.0.") var folder: String

        func run() throws {
            let manifest = try RuntimeStore(paths: env.paths).install(directory: URL(fileURLWithPath: folder, isDirectory: true))
            print("Installed \(manifest.id)")
        }
    }
}

struct ComponentsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "components", abstract: "Manage graphics components.", subcommands: [ImportGPTK.self]
    )

    struct ImportGPTK: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import-gptk", abstract: "Stage D3DMetal from your Game Porting Toolkit download."
        )
        @OptionGroup var env: Environment
        @Argument(help: "Game_Porting_Toolkit_<version>.dmg") var dmg: String

        func run() throws {
            let components = URL(fileURLWithPath: env.components, isDirectory: true).standardizedFileURL
            let folder = try GPTKImporter.importToolkit(dmg: URL(fileURLWithPath: dmg), into: components)
            print("Staged \(folder.lastPathComponent) in \(components.path)")
        }
    }
}

struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show what the app detects in a Windows program.")
    @Argument var executable: String
    @Option(help: "Also save the program's icon to this .ico file.") var icon: String?

    func run() throws {
        let exe = URL(fileURLWithPath: executable).standardizedFileURL
        let result = try GameDetector.inspect(executable: exe)
        print("binary:     \(result.inspectedBinary.path)")
        print("cpu:        \(result.machine)")
        print("graphics:   \(result.graphicsAPIs.sorted().map(\.rawValue).joined(separator: ", "))")
        print("engine:     \(result.engine?.rawValue ?? "unknown")")
        print(".NET:       \(result.isDotNet ? "yes" : "no")")
        print("backend:    \(result.recommendedBackend.displayName)")
        for finding in result.antiCheat {
            print("anti-cheat: \(finding.kind.rawValue) (\(finding.severity.rawValue)) at \(finding.evidence)")
        }
        if let icon {
            guard let data = try PEFile.icon(contentsOf: exe) else { throw ValidationError("\(exe.lastPathComponent) has no icon") }
            try data.write(to: URL(fileURLWithPath: icon))
            print("icon:       \(data.count) bytes → \(icon)")
        }
    }
}

extension GraphicsBackend: ExpressibleByArgument {}
