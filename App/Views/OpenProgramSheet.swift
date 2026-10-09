import GameCore
import SwiftUI

/// Asked for every program opened from Finder, dropped or added: run it once, or add it to the library.
struct OpenProgramSheet: View {
    @Environment(AppModel.self) private var model
    let program: URL
    @State private var bottleID: Bottle.ID?
    @State private var name = ""
    @State private var inspection: GameInspection?
    @State private var inspectionError: String?
    @State private var icon: NSImage?

    var body: some View {
        let bottle = model.bottles.first { $0.id == bottleID }
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: icon ?? NSWorkspace.shared.icon(forFile: program.path))
                    .resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading) {
                    Text(program.lastPathComponent).font(.headline)
                    Text(program.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Form {
                TextField("Name in Library", text: $name)
                Picker("Bottle", selection: $bottleID) {
                    ForEach(model.bottles) { bottle in
                        Text(bottle.kind == .isolated ? "\(bottle.name) (isolated)" : bottle.name).tag(Optional(bottle.id))
                    }
                }
                if let inspection {
                    LabeledContent("Graphics", value: inspection.recommendedBackend.displayName)
                    LabeledContent("CPU", value: inspection.machine.description)
                    ForEach(inspection.antiCheat, id: \.evidence) { finding in
                        Label("\(finding.kind.rawValue): "
                              + (finding.severity == .blocksLaunch ? "this game won't run under Wine." : "online play may not work."),
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(finding.severity == .blocksLaunch ? .red : .orange)
                    }
                } else if let inspectionError {
                    Label(inspectionError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)

            if let bottle, model.needsImport(program, into: bottle) {
                Label("An isolated bottle only sees its own C: drive, so the program (and files next to it named like it) "
                      + "is copied into the bottle's Downloads folder. A game made of many files should be installed inside the bottle instead.",
                      systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if model.bottles.isEmpty {
                Label("Create a bottle under Setup first.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Run Once") {
                    guard let bottle else { return }
                    dismiss()
                    Task { await model.runOnce(program, bottle: bottle) }
                }
                .disabled(bottle == nil)
                Button("Add to Library") {
                    guard let bottle else { return }
                    let name = name.trimmingCharacters(in: .whitespaces)
                    dismiss()
                    Task { await model.addToLibrary(program, bottle: bottle, name: name.isEmpty ? nil : name) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bottle == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            bottleID = model.suggestedBottle(for: program)?.id
            icon = (try? PEFile.icon(contentsOf: program)).flatMap { $0 }.flatMap(NSImage.init(data:))
            name = Game.defaultName(for: program)
        }
        .task {
            guard program.pathExtension.lowercased() == "exe" else { return }
            let program = program
            do {
                inspection = try await Task.detached { try GameDetector.inspect(executable: program) }.value
            } catch {
                inspectionError = "This doesn't look like a Windows program (\(AppModel.describe(error)))."
            }
        }
    }

    /// Moves on to the next opened program, if any.
    private func dismiss() {
        model.openRequests.removeAll { $0 == program }
    }
}
