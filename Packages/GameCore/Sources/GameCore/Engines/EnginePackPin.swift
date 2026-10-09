// Written by scripts/package-engine.sh; don't edit by hand.

import Foundation

extension EnginePack {
    /// The engine pack this version of the app downloads on first launch.
    public static let current = EnginePack(
        version: "26.3.0-1",
        url: URL(string: "https://github.com/Prateek-Srivastav/corkscrew/releases/download/runtime-26.3.0-1/corkscrew-engine-26.3.0-1.tar.xz")!,
        sha256: "588d48e8dfbec89b13ed0e0ec9e3c2a43d2875518abb3753f14c8b8efcfa0d34",
        size: 319378724
    )
}
