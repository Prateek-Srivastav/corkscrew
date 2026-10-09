import GameCore
import SwiftUI

struct BottlesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Bottle.ID?
    @State private var isCreating = false
    @State private var bottleToReset: Bottle?

    var body: some View {
        List(selection: $selection) {
            ForEach(model.bottles) { bottle in
                BottleRow(bottle: bottle)
                    .contextMenu { actions(for: bottle) }
            }
        }
        .overlay {
            if model.bottles.isEmpty {
                ContentUnavailableView("No bottles", systemImage: "shippingbox",
                                       description: Text("A bottle is a Windows drive with its own settings and programs."))
            }
        }
        .navigationTitle("Bottles")
        .toolbar {
            ToolbarItemGroup {
                Button("Add Existing Bottle…", systemImage: "square.and.arrow.down") {
                    if let folder = Pickers.folder("Choose a bottle folder (it holds bottle.json and prefix).") {
                        model.importBottle(from: folder)
                    }
                }
                Button("New Bottle…", systemImage: "plus") { isCreating = true }
                    .disabled(model.runtimes.isEmpty)
            }
        }
        .inspector(isPresented: Binding(get: { selectedBottle != nil }, set: { if !$0 { selection = nil } })) {
            if let bottle = selectedBottle {
                BottleDetail(bottle: bottle, reset: { bottleToReset = bottle })
                    .inspectorColumnWidth(min: 280, ideal: 320)
            }
        }
        .sheet(isPresented: $isCreating) { NewBottleSheet() }
        .confirmationDialog("Reset \(bottleToReset?.name ?? "") to its clean state?",
                            isPresented: Binding(get: { bottleToReset != nil }, set: { if !$0 { bottleToReset = nil } }),
                            presenting: bottleToReset) { bottle in
            Button("Reset", role: .destructive) { model.resetToClean(bottle) }
        } message: { _ in
            Text("Everything installed or saved in it since it was created is discarded, and running programs are stopped.")
        }
    }

    private var selectedBottle: Bottle? { model.bottles.first { $0.id == selection } }

    @ViewBuilder
    private func actions(for bottle: Bottle) -> some View {
        Button("Run Program…") { runProgram(in: bottle) }
        Button("Show C: Drive in Finder") { NSWorkspace.shared.open(model.driveC(of: bottle)) }
        if model.runningBottles.contains(bottle.id) {
            Button("Stop Everything in It") { model.stop(bottle) }
        }
        if bottle.kind == .isolated {
            Divider()
            Button("Reset to Clean…", role: .destructive) { bottleToReset = bottle }
        }
    }

    private func runProgram(in bottle: Bottle) {
        guard let program = Pickers.programs().first else { return }
        Task { await model.runOnce(program, bottle: bottle) }
    }
}

private struct BottleRow: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: bottle.kind == .isolated ? "lock.shield.fill" : "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(bottle.kind == .isolated ? Color.orange : Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(bottle.name).font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.runningBottles.contains(bottle.id) {
                Label("Running", systemImage: "circle.fill").labelStyle(.titleAndIcon).font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        let games = model.games.filter { $0.bottleID == bottle.id }.count
        let kind = bottle.kind == .isolated
            ? "Isolated, " + (bottle.isolation.allowNetwork ? "internet on" : "offline")
            : "Standard"
        return "\(kind) · \(games) \(games == 1 ? "game" : "games")"
    }
}

private struct BottleDetail: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle
    let reset: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("Kind", value: bottle.kind == .isolated ? "Isolated (macOS sandbox)" : "Standard")
                if bottle.kind == .isolated {
                    LabeledContent("Internet", value: bottle.isolation.allowNetwork ? "Allowed" : "Blocked")
                    LabeledContent("Clipboard", value: bottle.isolation.allowClipboard ? "Allowed" : "Blocked")
                }
                LabeledContent("Windows", value: bottle.windowsVersion.rawValue)
                LabeledContent("Runtime", value: bottle.engineID)
                LabeledContent("Created", value: bottle.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Status", value: model.runningBottles.contains(bottle.id) ? "Running" : "Idle")
            }
            if bottle.kind == .isolated {
                Section {
                    Text("Programs here can't see your files, other apps or (unless allowed) the internet. "
                         + "Keep it offline, don't sign into accounts in it, and reset it after use. "
                         + "No sandbox is perfect: macOS or GPU driver bugs can still be exploited.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Run Program…") {
                    guard let program = Pickers.programs().first else { return }
                    Task { await model.runOnce(program, bottle: bottle) }
                }
                Button("Show C: Drive in Finder") { NSWorkspace.shared.open(model.driveC(of: bottle)) }
                Button("Stop Everything in It") { model.stop(bottle) }
                    .disabled(!model.runningBottles.contains(bottle.id))
                if bottle.kind == .isolated {
                    Button("Reset to Clean…", role: .destructive, action: reset)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(bottle.name)
    }
}

struct NewBottleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = Bottle.Kind.standard
    @State private var allowNetwork = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Bottle").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text(kind == .isolated ? "Untrusted" : "Games"))
                Picker("Kind", selection: $kind) {
                    Text("Standard").tag(Bottle.Kind.standard)
                    Text("Isolated").tag(Bottle.Kind.isolated)
                }
                .pickerStyle(.segmented)
                if kind == .isolated {
                    Toggle("Allow internet", isOn: $allowNetwork)
                    Text("For programs you don't trust, like installers from unknown sites. They run in a macOS sandbox "
                         + "that hides your files and other apps.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("For games and launchers like Steam. Programs here can read your files, as on Windows.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    model.createBottle(name: trimmed.isEmpty ? (kind == .isolated ? "Untrusted" : "Games") : trimmed,
                                       kind: kind, allowNetwork: kind == .isolated && allowNetwork)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
