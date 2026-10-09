// Written by scripts/package-engine.sh; don't edit by hand.

import Foundation

extension EnginePack {
    /// The engine pack this version of the app downloads on first launch.
    public static let current = EnginePack(
        version: "26.3.0-2",
        url: URL(string: "https://github.com/Prateek-Srivastav/corkscrew/releases/download/runtime-26.3.0-2/corkscrew-engine-26.3.0-2.tar.xz")!,
        sha256: "4d5a419d80df7695ae74cef3861fbdb43bf01b6c218dc80b11b9da2106b9f23b",
        size: 319399464
    )
}
