import Foundation
import Testing
@testable import GameCore

struct ComponentCatalogTests {
    @Test func wiresStagedBackendsIntoTheEngine() throws {
        try withTempDir { root in
            let components = root.appending(path: "Components", directoryHint: .isDirectory)
            for folder in ["dxmt-0.9", "dxmt-0.80", "dxvk-macos-1.10.3-20230507-repack", "d3dmetal-3.0/wine"] {
                try components.appending(path: folder).makeDirectory()
            }
            let engine = try ComponentCatalog.engine(
                id: "winecx", root: root.appending(path: "runtime"), architecture: .x86_64, components: components
            )

            // Numeric comparison: 0.80 is newer than 0.9.
            #expect(engine.backendDLLPaths[.dxmt]?.map(\.lastPathComponent) == ["dxmt-0.80"])
            #expect(engine.backendDLLPaths[.dxvk]?.map(\.lastPathComponent) == ["dxvk-macos-1.10.3-20230507-repack"])
            // Directory listings report /private/var for the temp folder, so compare real paths.
            let real = { (url: URL) in SandboxProfile.canonicalPath(url) }
            #expect(engine.backendDLLPaths[.d3dmetal]?.map(real) == [real(components.appending(path: "d3dmetal-3.0/wine"))])
            let shared = try #require(engine.backendEnvironment[.d3dmetal]?["CX_APPLEGPTK_LIBD3DSHARED_PATH"])
            #expect(real(URL(fileURLWithPath: shared)) == real(components.appending(path: "d3dmetal-3.0/external/libd3dshared.dylib")))
            #expect(ComponentCatalog.availableBackends(of: engine) == [.dxmt, .dxvk, .d3dmetal, .wined3d])
        }
    }

    @Test func pinsAStagedD3DMetalVersion() throws {
        try withTempDir { root in
            let components = root.appending(path: "Components", directoryHint: .isDirectory)
            for folder in ["d3dmetal-3.0/wine", "d3dmetal-4.0b2/wine"] {
                try components.appending(path: folder).makeDirectory()
            }
            let engine = { (version: String?) in
                try ComponentCatalog.engine(id: "winecx", root: root, architecture: .x86_64, components: components,
                                            d3dmetalVersion: version)
            }
            let folder = { (engine: Engine) in engine.backendDLLPaths[.d3dmetal]?.first?.deletingLastPathComponent().lastPathComponent }

            // A beta never wins by default over a stable toolkit, but can be picked by name.
            #expect(try folder(engine(nil)) == "d3dmetal-3.0")
            #expect(try folder(engine("4.0b2")) == "d3dmetal-4.0b2")
            #expect(throws: ComponentCatalog.Error.self) { try engine("5.0") }
        }
    }

    @Test func betaIsTheDefaultOnlyWhenNothingStableIsStaged() throws {
        try withTempDir { root in
            let components = root.appending(path: "Components", directoryHint: .isDirectory)
            try components.appending(path: "d3dmetal-4.0b2/wine").makeDirectory()
            #expect(ComponentCatalog.newest("d3dmetal-", in: components)?.lastPathComponent == "d3dmetal-4.0b2")
            try components.appending(path: "d3dmetal-3.0/wine").makeDirectory()
            #expect(ComponentCatalog.newest("d3dmetal-", in: components)?.lastPathComponent == "d3dmetal-3.0")
        }
    }

    @Test func withoutComponentsOnlyWineD3DIsAvailable() throws {
        try withTempDir { root in
            let engine = try ComponentCatalog.engine(
                id: "winecx", root: root, architecture: .x86_64, components: root.appending(path: "missing")
            )
            #expect(engine.backendDLLPaths.isEmpty)
            #expect(ComponentCatalog.availableBackends(of: engine) == [.wined3d])
        }
    }
}
