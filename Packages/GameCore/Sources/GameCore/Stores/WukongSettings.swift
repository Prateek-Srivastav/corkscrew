import Foundation

/// Black Myth: Wukong Benchmark Tool's graphics settings. Its first run picks FSR 3 with Frame
/// Generation, and DX12 under D3DMetal with Frame Generation on crashes at startup or stays black
/// (every failed launch on 2026-10-07/08). The tested setup has Frame Generation off and DLSS, which
/// D3DMetal turns into MetalFX.
enum WukongSettings {
    static let appID = "3132990"

    /// `b1/Saved/Config/Windows/GameUserSettings.ini` in the game's Steam folder.
    static func settingsFile(installFolder: URL) -> URL {
        installFolder.appending(path: "b1/Saved/Config/Windows/GameUserSettings.ini")
    }

    /// Before the first launch: DLSS (MetalFX) without Frame Generation. The game fills in the rest.
    static let firstLaunchSettings = """
        [/Script/GSGameSettings.GSGameUserSettings]
        UISettingData=(("Dlss", "2"),("SuperResolutionSampling", "2"),("InsertFrame", "0"))

        """

    /// Turns Frame Generation off, or writes `firstLaunchSettings` when the game has none yet. Other
    /// choices (FSR without Frame Generation, quality) stay the player's. Returns whether it changed
    /// anything.
    static func apply(installFolder: URL) throws -> Bool {
        let file = settingsFile(installFolder: installFolder)
        guard FileManager.default.fileExists(atPath: file.path) else {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(firstLaunchSettings.utf8).write(to: file)
            return true
        }
        // Not text we know: leave the player's file alone.
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        let frameGeneration = /\("InsertFrame",\s*"(?!0")[^"]*"\)/
        guard text.contains(frameGeneration) else { return false }
        try Data(text.replacing(frameGeneration, with: #"("InsertFrame", "0")"#).utf8).write(to: file, options: .atomic)
        return true
    }
}
