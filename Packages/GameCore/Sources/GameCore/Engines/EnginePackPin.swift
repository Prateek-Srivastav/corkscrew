// Written by scripts/package-engine.sh; don't edit by hand.

import Foundation

extension EnginePack {
    /// The engine pack this version of the app downloads on first launch.
    public static let current = EnginePack(
        version: "26.3.0-1",
        url: URL(string: "https://github.com/Prateek-Srivastav/corkscrew/releases/download/runtime-26.3.0-1/corkscrew-engine-26.3.0-1.tar.xz")!,
        sha256: "39421db1042688aeff036f5b3488e4d11463722bcaad947155d2f53c1d4e9dae",
        size: 319373244
    )
}
