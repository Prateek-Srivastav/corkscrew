import Foundation
import Testing
@testable import GameCore

struct WukongSettingsTests {
    /// The settings the benchmark's first run saved on 2026-10-07, which crashed on DX12.
    static let firstRunSettings = """
        [/Script/GSGameSettings.GSGameUserSettings]
        DesiredScreenWidth=876
        UISettingData=(("MainDisplay", "0"),("Dlss", "1"),("Dx12", "0"),("SuperResolutionSampling", "0"),("InsertFrame", "1"),("Rtx", "0"))
        PrivacyAgreement=1

        """

    @Test func turnsFrameGenerationOffAndKeepsTheRest() throws {
        try withTempDir { game in
            let file = WukongSettings.settingsFile(installFolder: game)
            try file.write(Self.firstRunSettings)

            #expect(try WukongSettings.apply(installFolder: game))
            #expect(try String(contentsOf: file, encoding: .utf8)
                == Self.firstRunSettings.replacingOccurrences(of: #"("InsertFrame", "1")"#, with: #"("InsertFrame", "0")"#))
            // Already off: the file isn't touched.
            #expect(try WukongSettings.apply(installFolder: game) == false)
        }
    }

    @Test func writesTheTestedSettingsBeforeTheFirstLaunch() throws {
        try withTempDir { game in
            #expect(try WukongSettings.apply(installFolder: game))
            let text = try String(contentsOf: WukongSettings.settingsFile(installFolder: game), encoding: .utf8)
            #expect(text.contains(#"("Dlss", "2")"#))
            #expect(text.contains(#"("InsertFrame", "0")"#))
        }
    }

    @Test func leavesAFileItCantReadAlone() throws {
        try withTempDir { game in
            let file = WukongSettings.settingsFile(installFolder: game)
            let utf16 = Data([0xFF, 0xFE]) + Self.firstRunSettings.data(using: .utf16LittleEndian)!
            try file.write(utf16)
            #expect(try WukongSettings.apply(installFolder: game) == false)
            #expect(try Data(contentsOf: file) == utf16)
        }
    }
}
