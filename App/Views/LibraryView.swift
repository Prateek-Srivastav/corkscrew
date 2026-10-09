import GameCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Game.ID?
    @State private var isDropTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 170), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            if !model.transientSessions.isEmpty {
                section("Running now") {
                    ForEach(model.transientSessions, id: \.game.id) { session in
                        GameCard(game: session.game, isSelected: false)
                            .contextMenu { Button("Stop") { model.stop(session.game) } }
                    }
                }
            }
            if model.games.isEmpty {
                ContentUnavailableView {
                    Label("No games yet", systemImage: "gamecontroller")
                } description: {
                    Text("Drop a Windows program (.exe) or installer (.msi) here, open one from Finder, or add one.")
                } actions: {
                    Button("Add Program…") { model.open(Pickers.programs()) }
                        .disabled(!model.isSetUp)
                }
                .padding(.top, 60)
            } else {
                let installed = model.games.filter { model.installState(of: $0) == .installed }
                let notDownloaded = model.games.filter { model.installState(of: $0) != .installed }
                if !installed.isEmpty {
                    section(model.transientSessions.isEmpty && notDownloaded.isEmpty ? nil : "Library") { cards(installed) }
                }
                if !notDownloaded.isEmpty {
                    section("Not Downloaded") { cards(notDownloaded) }
                }
            }
        }
        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : .clear)
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem {
                Button("Add Program…", systemImage: "plus") { model.open(Pickers.programs()) }
                    .disabled(!model.isSetUp)
            }
        }
        .inspector(isPresented: Binding(get: { selectedGame != nil }, set: { if !$0 { selection = nil } })) {
            if let game = selectedGame {
                GameDetailView(game: game).id(game.id)
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
            }
        }
    }

    private var selectedGame: Game? { model.games.first { $0.id == selection } }

    private func cards(_ games: [Game]) -> some View {
        ForEach(games) { game in
            GameCard(game: game, isSelected: selection == game.id)
                .onTapGesture(count: 2) { model.play(game) }
                .onTapGesture { selection = game.id }
                .contextMenu { menu(for: game) }
        }
    }

    private func section(_ title: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.headline).foregroundStyle(.secondary) }
            LazyVGrid(columns: columns, spacing: 18, content: content)
        }
        .padding(20)
    }

    @ViewBuilder
    private func menu(for game: Game) -> some View {
        if model.session(for: game)?.isActive == true {
            Button("Stop") { model.stop(game) }
        } else if model.installState(of: game) != .installed {
            Button("Open in Steam") { model.openInSteam(game) }
        } else {
            Button("Play") { model.play(game) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.iconSource ?? game.executable]) }
        }
        Divider()
        Button("Remove from Library", role: .destructive) {
            if selection == game.id { selection = nil }
            model.remove(game)
        }
    }
}

struct GameCard: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        let session = model.session(for: game)
        let state = model.installState(of: game)
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                GameIcon(game: game, size: 72)
                    .saturation(state == .installed ? 1 : 0)
                    .opacity(state == .installed ? 1 : 0.5)
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(.quaternary.opacity(isSelected ? 1 : 0.5), in: .rect(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                    }
                if session?.isActive == true {
                    Circle().fill(.green).frame(width: 12, height: 12).padding(8).help(session?.status.text ?? "")
                } else if isHovering {
                    Button { model.play(game) } label: {
                        Image(systemName: state == .installed ? "play.fill" : "arrow.down").padding(6)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(.circle)
                    .padding(6)
                    .help(state == .installed ? "Play" : "Open in Steam to download")
                }
            }
            VStack(spacing: 2) {
                Text(game.name).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                Text(subtitle(state))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }

    private func subtitle(_ state: Steam.InstallState) -> String {
        switch state {
        case .installed: (model.bottle(for: game)?.name ?? "No bottle") + (game.store?.store == Steam.store ? " · Steam" : "")
        case .downloading: "Downloading in Steam"
        case .notInstalled: "Not downloaded"
        }
    }
}
