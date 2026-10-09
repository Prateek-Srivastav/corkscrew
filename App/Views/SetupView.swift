import GameCore
import SwiftUI

/// First-run setup, and where runtimes and graphics components are managed later.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var archiveSHA256 = ""
    @State private var isCreatingBottle = false

    var body: some View {
        Form {
            Section {
                Text("Corkscrew runs Windows games with Wine. It needs a Wine runtime, the graphics translators, "
                     + "and a bottle (a Windows drive) to install games into.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if model.runtimes.isEmpty {
                    Text("No runtime installed.").foregroundStyle(.secondary)
                }
                ForEach(model.runtimes, id: \.id) { runtime in
                    LabeledContent(runtime.id, value: [runtime.architecture.rawValue, runtime.moltenVK.map { "MoltenVK \($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                }
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
            } header: {
                step(1, "Wine runtime", done: !model.runtimes.isEmpty)
            }

            Section {
                if model.components.isEmpty {
                    Text("None yet. Without them games use WineD3D, which is slow for DirectX 10–12.").foregroundStyle(.secondary)
                }
                ForEach(model.components, id: \.self) { Text($0) }
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
                Text("D3DMetal (DirectX 12) comes from your own Game Porting Toolkit download at developer.apple.com.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                step(2, "Graphics components", done: !model.components.isEmpty)
            }

            Section {
                ForEach(model.bottles) { bottle in
                    Label(bottle.name, systemImage: bottle.kind == .isolated ? "lock.shield" : "shippingbox")
                }
                if !model.bottles.contains(where: { $0.kind == .standard && $0.name == "Games" }) {
                    Button("Create the “Games” Bottle") { model.createBottle(name: "Games", kind: .standard) }
                        .disabled(model.runtimes.isEmpty || model.activity != nil)
                }
                Button("New Bottle…") { isCreatingBottle = true }
                    .disabled(model.runtimes.isEmpty)
                Button("Add Existing Bottle…") {
                    if let folder = Pickers.folder("Choose a bottle folder (it holds bottle.json and prefix).") {
                        model.importBottle(from: folder)
                    }
                }
            } header: {
                step(3, "Bottle", done: !model.bottles.isEmpty)
            }

            Section("Data") {
                LabeledContent("Bottles and runtimes") { pathButton(model.paths.supportRoot) }
                LabeledContent("Logs") { pathButton(model.paths.logsRoot) }
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
