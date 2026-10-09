import Foundation
import Testing
@testable import GameCore

struct PEIconTests {
    private let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47] + Array(repeating: 0xAB, count: 40)
    private let bitmap: [UInt8] = Array(repeating: 0x28, count: 30)

    private func u16(_ data: Data, _ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset + 1]) << 8 }
    private func u32(_ data: Data, _ offset: Int) -> UInt32 { UInt32(u16(data, offset)) | UInt32(u16(data, offset + 2)) << 16 }

    @Test func buildsAnIcoFileFromTheFirstIconGroup() throws {
        var pe = PEBuilder()
        pe.resources = [
            3: [(id: 1, data: png), (id: 2, data: bitmap), (id: 9, data: [1, 2, 3])],
            // Two groups: Windows (and we) use the first one.
            14: [(id: 100, data: PEBuilder.iconGroup([(id: 1, width: 0, size: 999), (id: 2, width: 32, size: png.count)])),
                 (id: 200, data: PEBuilder.iconGroup([(id: 9, width: 16, size: 3)]))],
        ]
        let ico = try #require(try PEFile.icon(in: pe.build()))

        #expect(u16(ico, 2) == 1)
        #expect(u16(ico, 4) == 2)
        // Entry 1: 256 px (stored as 0), the real byte count, data right after the directory.
        #expect(ico[6] == 0)
        #expect(u32(ico, 6 + 8) == UInt32(png.count))
        #expect(u32(ico, 6 + 12) == 6 + 2 * 16)
        #expect(ico[22] == 32)
        #expect(u32(ico, 22 + 8) == UInt32(bitmap.count))
        #expect(u32(ico, 22 + 12) == UInt32(6 + 2 * 16 + png.count))
        #expect(Array(ico.suffix(png.count + bitmap.count)) == png + bitmap)
    }

    @Test func noIconWhenThereAreNoResourcesOrTheGroupPointsNowhere() throws {
        #expect(try PEFile.icon(in: PEBuilder().build()) == nil)

        var dangling = PEBuilder()
        dangling.resources = [3: [(id: 1, data: png)], 14: [(id: 1, data: PEBuilder.iconGroup([(id: 7, width: 32, size: 4)]))]]
        #expect(try PEFile.icon(in: dangling.build()) == nil)

        var noIcons = PEBuilder()
        noIcons.resources = [14: [(id: 1, data: PEBuilder.iconGroup([(id: 1, width: 32, size: 4)]))]]
        #expect(try PEFile.icon(in: noIcons.build()) == nil)
    }

    @Test func survivesAGroupThatClaimsMoreIconsThanItHolds() throws {
        var group = PEBuilder.iconGroup([(id: 1, width: 32, size: png.count)])
        group[4] = 0xFF  // count 255, but only one entry follows
        var pe = PEBuilder()
        pe.resources = [3: [(id: 1, data: png)], 14: [(id: 1, data: group)]]
        let ico = try #require(try PEFile.icon(in: pe.build()))
        #expect(u16(ico, 4) == 1)
    }

    @Test func refusesFilesThatArentPE() {
        #expect(throws: PEFile.ParseError.notPE) { try PEFile.icon(in: Data("not a program".utf8)) }
    }
}
