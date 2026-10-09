import GameCore
import SwiftUI

struct GameDetailView: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @State private var arguments = ""
    @State private var selectedLog: URL?
    @State private var logs: [URL] = []

    var body: some View {
        let session = model.session(for: game)
        let isActive = session?.isActive == true
        let state = model.installState(of: game)
        Form {
            Section {
                HStack(spacing: 14) {
                    GameIcon(game: game, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Name", text: binding(\.name)).labelsHidden()
                            .font(.title3.weight(.semibold)).textFieldStyle(.plain)
                        Text(game.store?.appID != nil ? "Starts through Steam" : game.executable.lastPathComponent)
                            .font(.caption).foregroundStyle(.secondary)
                            .help((game.iconSource ?? game.executable).path)
                    }
                }
                HStack {
                    if isActive {
                        Button("Stop", systemImage: "stop.fill", role: .destructive) { model.stop(game) }
                    } else if state != .installed {
                        Button("Open in Steam", systemImage: "arrow.down.circle") { model.openInSteam(game) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Play", systemImage: "play.fill") { model.play(game) }
                            .buttonStyle(.borderedProminent)
                    }
                    if let session { Text(session.status.text).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
                }
                if state != .installed {
                    Label(state == .downloading
                          ? "Downloading in Steam. It's ready to play once Steam finishes."
                          : "Not downloaded. Steam's page for it has the Install button; these settings are kept for when it's back.",
                          systemImage: "arrow.down.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(session?.notes ?? [], id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Launch") {
                LabeledContent("Bottle") {
                    HStack(spacing: 4) {
                        if model.bottle(for: game)?.kind == .isolated { Image(systemName: "lock.shield").help("Isolated") }
                        Text(model.bottle(for: game)?.name ?? "Missing")
                    }
                }
                Picker("Graphics", selection: binding(\.profile.backendOverride)) {
                    Text("Automatic").tag(GraphicsBackend?.none)
                    ForEach(availableBackends, id: \.self) { backend in
                        Text(backend.displayName).tag(Optional(backend))
                    }
                }
                Toggle("MetalFX upscaling (D3DMetal and DXMT, via the game's DLSS option)", isOn: binding(\.profile.metalFX))
                Toggle("Retina resolution", isOn: binding(\.profile.retinaMode))
                    .help("The game sees the display's full pixel resolution: sharper, much more GPU work. Applies to the whole bottle.")
                Toggle("Metal HUD (FPS)", isOn: binding(\.profile.metalHUD))
                Toggle("CPU / RAM / GPU overlay", isOn: binding(\.profile.performanceOverlay))
                Toggle("Advertise AVX", isOn: binding(\.profile.advertiseAVX))
                Toggle("Steam overlay (Shift-Tab)", isOn: binding(\.profile.steamOverlay))
                    .help("Steam's overlay sits between the game and the graphics layer and draws every frame. Off is faster. Games started from Steam's window follow the setting Steam was started with.")
                Toggle("Wine error output in the log", isOn: binding(\.profile.verboseLogging))
                TextField("Arguments", text: $arguments, prompt: Text("-dx11 -windowed"))
                    .onSubmit(saveArguments)
                    .onChange(of: arguments) { saveArguments() }
            }
            .disabled(isActive)

            Section("Logs") {
                if logs.isEmpty {
                    Text("No launches yet.").foregroundStyle(.secondary)
                } else {
                    Picker("Launch", selection: $selectedLog) {
                        ForEach(logs, id: \.self) { log in
                            Text(LaunchLogLabel.text(for: log)).tag(Optional(log))
                        }
                    }
                    if let selectedLog {
                        LogView(file: selectedLog, isLive: isActive && selectedLog == session?.log)
                            .frame(minHeight: 220)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([selectedLog]) }
                    }
                }
            }

            Section {
                Button("Show Program in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.iconSource ?? game.executable]) }
                    .disabled(state != .installed)
                Button("Remove from Library", role: .destructive) { model.remove(game) }
                    .disabled(isActive)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            arguments = ArgumentText.join(game.profile.arguments)
            refreshLogs()
        }
        .onChange(of: session?.log) { refreshLogs() }
    }

    private var availableBackends: [GraphicsBackend] {
        guard let bottle = model.bottle(for: game),
              let engine = try? RuntimeStore(paths: model.paths).engine(id: bottle.engineID)
        else { return [.wined3d] }
        let available = ComponentCatalog.availableBackends(of: engine)
        return [GraphicsBackend.d3dmetal, .dxmt, .dxvk, .wined3d].filter(available.contains)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Game, T>) -> Binding<T> {
        Binding(
            get: { (model.games.first { $0.id == game.id } ?? game)[keyPath: keyPath] },
            set: { value in
                var updated = model.games.first { $0.id == game.id } ?? game
                updated[keyPath: keyPath] = value
                model.update(updated)
            }
        )
    }

    private func saveArguments() {
        binding(\.profile.arguments).wrappedValue = ArgumentText.split(arguments)
    }

    private func refreshLogs() {
        logs = LaunchLogs.list(for: game.id, paths: model.paths)
        if selectedLog == nil || !logs.contains(selectedLog!) { selectedLog = logs.first }
        if let current = model.session(for: game)?.log { selectedLog = current }
    }
}

enum LaunchLogLabel {
    /// "launch-2026-10-08_02-34-45.log" → "8 Oct 2026 at 02:34:45".
    static func text(for log: URL) -> String {
        let stamp = log.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "launch-", with: "")
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        guard let date = parser.date(from: stamp) else { return log.lastPathComponent }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}

/// Program arguments as one line: split on spaces, with "double quotes" around arguments that contain them.
enum ArgumentText {
    static func split(_ text: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var quoted = false
        var hasArgument = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
                hasArgument = true
            } else if character.isWhitespace, !quoted {
                if hasArgument { arguments.append(current) }
                current = ""
                hasArgument = false
            } else {
                current.append(character)
                hasArgument = true
            }
        }
        if hasArgument { arguments.append(current) }
        return arguments
    }

    static func join(_ arguments: [String]) -> String {
        arguments.map { $0.isEmpty || $0.contains(where: \.isWhitespace) ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }
}
