import Foundation

/// Per-game launch settings.
public struct GameProfile: Codable, Sendable, Equatable {
    /// `nil` means Auto: pick from the game's detected graphics APIs.
    public var backendOverride: GraphicsBackend?
    /// D3DMetal only: exposes MetalFX upscaling to games through their DLSS option.
    public var metalFX: Bool
    /// Render at full Retina resolution (sharper, slower). Applied to the prefix registry before launch.
    public var retinaMode: Bool
    /// Apple's Metal performance HUD (FPS, GPU time, memory).
    public var metalHUD: Bool
    /// Our CPU / RAM / GPU panel (`perf-overlay`) while the game runs.
    public var performanceOverlay: Bool
    /// Tell games Rosetta supports AVX/AVX2; some refuse to start without it.
    public var advertiseAVX: Bool
    /// Wine debug output in the launch log (slower).
    public var verboseLogging: Bool
    public var arguments: [String]
    /// Extra environment variables; these win over everything the app sets.
    public var environment: [String: String]

    public init(
        backendOverride: GraphicsBackend? = nil,
        metalFX: Bool = false,
        retinaMode: Bool = false,
        metalHUD: Bool = false,
        performanceOverlay: Bool = false,
        advertiseAVX: Bool = true,
        verboseLogging: Bool = false,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) {
        self.backendOverride = backendOverride
        self.metalFX = metalFX
        self.retinaMode = retinaMode
        self.metalHUD = metalHUD
        self.performanceOverlay = performanceOverlay
        self.advertiseAVX = advertiseAVX
        self.verboseLogging = verboseLogging
        self.arguments = arguments
        self.environment = environment
    }

    /// Profiles are saved in `library.json`; settings added later get their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GameProfile()
        backendOverride = try c.decodeIfPresent(GraphicsBackend.self, forKey: .backendOverride)
        metalFX = try c.decodeIfPresent(Bool.self, forKey: .metalFX) ?? defaults.metalFX
        retinaMode = try c.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? defaults.retinaMode
        metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? defaults.metalHUD
        performanceOverlay = try c.decodeIfPresent(Bool.self, forKey: .performanceOverlay) ?? defaults.performanceOverlay
        advertiseAVX = try c.decodeIfPresent(Bool.self, forKey: .advertiseAVX) ?? defaults.advertiseAVX
        verboseLogging = try c.decodeIfPresent(Bool.self, forKey: .verboseLogging) ?? defaults.verboseLogging
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? defaults.arguments
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? defaults.environment
    }
}
