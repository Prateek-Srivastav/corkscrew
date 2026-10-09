import GameCore
import SwiftUI

enum SidebarItem: Hashable {
    case library, bottles, setup
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .library

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $selection) {
                Label("Library", systemImage: "square.grid.2x2").tag(SidebarItem.library)
                Label("Bottles", systemImage: "shippingbox").tag(SidebarItem.bottles)
                Label("Setup", systemImage: "wrench.and.screwdriver")
                    .badge(model.isSetUp ? 0 : 1)
                    .tag(SidebarItem.setup)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch selection ?? .library {
            case .library: LibraryView()
            case .bottles: BottlesView()
            case .setup: SetupView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let activity = model.activity {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activity).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
        .sheet(isPresented: Binding(get: { !model.openRequests.isEmpty }, set: { if !$0 { model.openRequests = [] } })) {
            if let program = model.openRequests.first {
                OpenProgramSheet(program: program).id(program)
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear { if !model.isSetUp { selection = .setup } }
    }
}

/// A program's icon, or a generic one.
struct GameIcon: View {
    @Environment(AppModel.self) private var model
    let game: Game
    var size: CGFloat = 64

    var body: some View {
        Group {
            if let image = model.icon(for: game) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable().fontWeight(.ultraLight).foregroundStyle(.secondary)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
    }
}

extension AppModel.Session.Status {
    var text: String {
        switch self {
        case .preparing: "Starting…"
        case .running: "Running"
        case .exited(0): "Exited normally"
        case .exited(let code): "Exited with code \(code)"
        case .stopped: "Stopped"
        case .failed(let message): "Couldn't start: \(message)"
        }
    }
}
