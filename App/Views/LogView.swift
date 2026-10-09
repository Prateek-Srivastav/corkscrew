import SwiftUI

/// A launch log, following new output while the launch runs.
struct LogView: View {
    let file: URL
    let isLive: Bool
    @State private var text = ""

    /// Logs can grow large (verbose Wine output); only the end is shown.
    private static let tailBytes = 256 * 1024

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                Text(text.isEmpty ? " " : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                Color.clear.frame(height: 1).id("end")
            }
            .background(.background.secondary, in: .rect(cornerRadius: 6))
            .task(id: "\(file.path) \(isLive)") {
                repeat {
                    let latest = Self.read(file)
                    if latest != text {
                        text = latest
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                    try? await Task.sleep(for: .seconds(1))
                } while isLive && !Task.isCancelled
            }
        }
    }

    private static func read(_ file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        let content = String(decoding: data, as: UTF8.self)
        return start > 0 ? "… (earlier output not shown)\n" + content : content
    }
}
