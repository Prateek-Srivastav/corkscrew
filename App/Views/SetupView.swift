import GameCore
import SwiftUI

/// First-run setup, and where runtimes and graphics components are managed later.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var archiveSHA256 = ""
    @State private var isCreatingBottle = false
    @State private var showsAdvanced = false

    static let gameportingToolkitPage = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!

    var body: some View {
        Form {
            Section {
                Text("Corkscrew runs Windows games with Wine. One click sets up everything: Rosetta if your Mac needs it, "
                     + "Wine with its graphics translators (D3DMetal, DXMT and DXVK), a bottle (a Windows drive) for your games, and Steam.")
                    .foregroundStyle(.secondary)
                if model.isSettingUp {
                    HStack {
                        if let progress = model.enginePackProgress {
                            ProgressView(value: progress) {
                                Text("Downloading Wine… \(Int(progress * 100))% of \(ByteCountFormatter.string(fromByteCount: AppModel.enginePack.size, countStyle: .file))")
                            }
                        } else {
                            ProgressView().controlSize(.small)
                            Text(model.activity ?? "Setting up…").lineLimit(2)
                        }
                        Spacer()
                        Button("Cancel") { model.cancelSetUp() }
                    }
                } else if !model.isSetUp || !model.hasSteam {
                    Button("Set Up Corkscrew") { model.setUp() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.activity != nil)
                    Text("Downloads \(ByteCountFormatter.string(fromByteCount: AppModel.enginePack.size, countStyle: .file)) for Wine; Steam updates itself the first time it opens. "
                         + "If Rosetta isn't installed yet, macOS asks for your password once.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Ready. Open Steam from the Library, sign in, and install your games.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Section {
                step(1, "Rosetta", done: model.hasRosetta)
                step(2, "Wine runtime and graphics", done: !model.runtimes.isEmpty)
                step(3, "“Games” bottle", done: model.gamesBottle != nil)
                step(4, "Steam", done: model.hasSteam)
            }

            Section("Installed") {
                ForEach(model.runtimes, id: \.id) { runtime in
                    LabeledContent(runtime.id, value: [runtime.architecture.rawValue, runtime.moltenVK.map { "MoltenVK \($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                }
                ForEach(model.components, id: \.self) { Text($0) }
                if model.runtimes.isEmpty && model.components.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
            }

            Section("Bottles") {
                ForEach(model.bottles) { bottle in
                    Label(bottle.name, systemImage: bottle.kind == .isolated ? "lock.shield" : "shippingbox")
                }
                if let games = model.gamesBottle, !model.hasSteam, !model.isSettingUp {
                    Button("Install Steam into “Games”") { Task { await model.installSteam(into: games) } }
                        .disabled(model.activity != nil)
                }
                Button("New Bottle…") { isCreatingBottle = true }
                    .disabled(model.runtimes.isEmpty)
                Button("Add Existing Bottle…") {
                    if let folder = Pickers.folder("Choose a bottle folder (it holds bottle.json and prefix).") {
                        model.importBottle(from: folder)
                    }
                }
            }

            Section("Data") {
                LabeledContent("Bottles and runtimes") { pathButton(model.paths.supportRoot) }
                LabeledContent("Logs") { pathButton(model.paths.logsRoot) }
            }

            Section {
                DisclosureGroup("Advanced: your own runtimes and components", isExpanded: $showsAdvanced) {
                    Button("Add Runtime Folder…") {
                        if let folder = Pickers.folder("Choose a runtime built on this Mac (build/runtime/winecx-…).") {
                            model.installRuntime(folder: folder)
                        }
                    }
                    HStack {
                        TextField("Archive SHA-256", text: $archiveSHA256, prompt: Text("64 hex characters"))
                            .font(.system(.body, design: .monospaced))
                        Button("Install Archive…") {
                            if let archive = Pickers.file("Choose a runtime archive.", extensions: ["xz", "gz", "zst", "tar"]) {
                                model.installRuntime(archive: archive, sha256: archiveSHA256)
                            }
                        }
                        .disabled(archiveSHA256.trimmingCharacters(in: .whitespaces).count != 64)
                    }
                    Button("Add Components Folder…") {
                        if let folder = Pickers.folder("Choose the folder install-components.sh filled (build/components).") {
                            model.importComponents(from: folder)
                        }
                    }
                    Button("Import Game Porting Toolkit…") {
                        if let dmg = Pickers.file("Choose Apple's Game Porting Toolkit disk image (Game_Porting_Toolkit_<version>.dmg).",
                                                  extensions: ["dmg"]) {
                            model.importGPTK(dmg: dmg)
                        }
                    }
                    Text("D3DMetal 3.0 comes with the runtime. To try another version, download it from Apple's Game Porting Toolkit page and import its disk image.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Game Porting Toolkit at Apple", destination: Self.gameportingToolkitPage)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
        .sheet(isPresented: $isCreatingBottle) { NewBottleSheet() }
    }

    private func step(_ number: Int, _ title: String, done: Bool) -> some View {
        Label("\(number). \(title)", systemImage: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done ? Color.green : Color.secondary)
    }

    private func pathButton(_ url: URL) -> some View {
        Button(url.path(percentEncoded: false)) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        }
        .buttonStyle(.link)
        .lineLimit(1)
        .truncationMode(.middle)
    }
}
