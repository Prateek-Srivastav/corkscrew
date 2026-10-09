import AppKit
import GameCore

/// On-screen CPU / RAM / GPU readout for one bottle, shown above games (including fullscreen ones).
/// FPS and frame times come from Apple's Metal Performance HUD (top-right), so this sits top-left.
/// Usage: perf-overlay <bottle prefix>. Quits once the bottle's processes have all exited.
@main
@MainActor
enum PerfOverlay {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: perf-overlay <bottle prefix>\n".utf8))
            exit(64)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // no Dock icon, never takes focus from the game
        let controller = OverlayController(prefix: URL(fileURLWithPath: CommandLine.arguments[1]))
        controller.start()
        app.run()
    }
}

@MainActor
final class OverlayController {
    private let sampler: PerformanceSampler
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var sawProcesses = false
    private var idleSamples = 0

    init(prefix: URL) {
        sampler = PerformanceSampler(prefix: prefix)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 74),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false

        let background = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        background.layer?.cornerRadius = 8
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.maximumNumberOfLines = 3
        label.frame = background.bounds.insetBy(dx: 10, dy: 8)
        label.autoresizingMask = [.width, .height]
        background.addSubview(label)
        panel.contentView = background
    }

    func start() {
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: visible.minX + 12, y: visible.maxY - 12))
        }
        label.stringValue = "Waiting for the game…"
        panel.orderFrontRegardless()
        _ = sampler.sample()   // prime the CPU baseline
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func update() {
        let s = sampler.sample()
        if s.processCount == 0 {
            idleSamples += 1
            // Leave once the game has exited, or if it never showed up.
            if (sawProcesses && idleSamples >= 5) || idleSamples >= 60 { NSApp.terminate(nil) }
            return
        }
        sawProcesses = true
        idleSamples = 0
        let gpu = s.gpuPercent.map { "\($0)%" } ?? "n/a"
        let gpuMemory = s.gpuMemoryBytes.map { " · \(gigabytes($0)) in use" } ?? ""
        label.stringValue = """
        CPU  \(String(format: "%4.0f", s.cpuPercent))%   (\(s.processCount) processes)
        RAM  \(gigabytes(s.memoryBytes)) game · \(gigabytes(s.systemMemoryUsed)) / \(gigabytes(s.systemMemoryTotal)) Mac
        GPU  \(gpu.padding(toLength: 4, withPad: " ", startingAt: 0))\(gpuMemory)
        """
    }

    private func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}
