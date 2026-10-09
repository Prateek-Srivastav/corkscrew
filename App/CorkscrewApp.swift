import AppKit
import GameCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct CorkscrewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Corkscrew", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 540)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Corkscrew") { AboutPanel.show() }
            }
            CommandGroup(after: .newItem) {
                Button("Add Program…") { model.open(Pickers.programs()) }
                    .keyboardShortcut("o")
            }
        }
    }
}

/// Finder's Open With and double-clicks arrive here, also when they launch the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.open(urls)
        NSApp.activate()
    }

    /// Games keep running when the window closes; quitting the app doesn't stop them either.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        WindowSnapshots.startIfRequested()
        // Development aid: `-DebugSetUp YES` starts the one-click setup, to test it without clicking.
        if UserDefaults.standard.bool(forKey: "DebugSetUp") { AppModel.shared.setUp() }
        #endif
    }
}

#if DEBUG
/// Development aid: with `-DebugSnapshotPath <file.png>` the app saves its main window there every
/// two seconds, so the UI can be checked without Screen Recording permission.
enum WindowSnapshots {
    static func startIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "DebugSnapshotPath") else { return }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.level == .normal }),
                      let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                // Sheets are separate windows; save the front one next to it.
                if let sheet = window.attachedSheet, let content = sheet.contentView,
                   let sheetRep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: sheetRep)
                    try? sheetRep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: (path as NSString).deletingPathExtension + "-sheet.png"))
                }
            }
        }
    }
}
#endif

/// The About panel, with the license notice the GPL asks an interactive program to show.
enum AboutPanel {
    static let source = URL(string: "https://github.com/Prateek-Srivastav/corkscrew")!

    static func show() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ]
        let credits = NSMutableAttributedString(string: """
            Runs Windows games on Apple Silicon Macs.

            Corkscrew is free software under the GNU General Public License, version 3 or later, \
            and comes with no warranty. Source code:

            """, attributes: body)
        var link = body
        link[.link] = source
        credits.append(NSAttributedString(string: source.absoluteString, attributes: link))
        credits.append(NSAttributedString(string: """


            Uses Wine, DXMT, DXVK, MoltenVK and other open-source components under their own licenses. \
            D3DMetal is Apple's, from the Game Porting Toolkit, under Apple's license for non-commercial use.
            """, attributes: body))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}

/// Open panels for the few files the app asks for.
enum Pickers {
    static func programs() -> [URL] {
        let panel = NSOpenPanel()
        panel.message = "Choose Windows programs (.exe) or installers (.msi)."
        panel.allowedContentTypes = [.init("com.microsoft.windows-executable"), .init("com.microsoft.msi")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func folder(_ message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func file(_ message: String, extensions: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.allowedContentTypes = extensions.compactMap { .init(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
