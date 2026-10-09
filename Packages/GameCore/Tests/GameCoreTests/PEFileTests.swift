import Foundation
import Testing
@testable import GameCore

struct PEFileTests {
    @Test func readsX64ImportsAndDelayImports() throws {
        let data = PEBuilder(imports: ["KERNEL32.dll", "d3d12.dll", "DXGI.dll"], delayImports: ["vulkan-1.dll"]).build()
        let pe = try PEFile(data: data)
        #expect(pe.machine == .x86_64)
        #expect(pe.format == .pe32Plus)
        #expect(pe.subsystem == 3)
        #expect(!pe.isDLL)
        #expect(!pe.isDotNet)
        #expect(pe.imports == ["kernel32.dll", "d3d12.dll", "dxgi.dll"])
        #expect(pe.delayImports == ["vulkan-1.dll"])
    }

    @Test func reads32BitImage() throws {
        let pe = try PEFile(data: PEBuilder(machine: 0x014C, pe32Plus: false, imports: ["d3d9.dll"]).build())
        #expect(pe.machine == .i386)
        #expect(pe.format == .pe32)
        #expect(pe.imports == ["d3d9.dll"])
    }

    @Test func flagsDLLsAndDotNet() throws {
        let pe = try PEFile(data: PEBuilder(isDLL: true, dotNet: true, imports: ["mscoree.dll"]).build())
        #expect(pe.isDLL)
        #expect(pe.isDotNet)
    }

    @Test func arm64Machine() throws {
        #expect(try PEFile(data: PEBuilder(machine: 0xAA64).build()).machine == .arm64)
    }

    @Test func rejectsNonPEData() {
        #expect(throws: PEFile.ParseError.notPE) { try PEFile(data: Data("#!/bin/sh\necho hi\n".utf8)) }
        var mz = Bytes()
        mz.zeros(0x40)
        mz.put16(0x5A4D, at: 0)
        mz.put32(0xFFFF_FF00, at: 0x3C) // e_lfanew far past the end
        #expect(throws: PEFile.ParseError.notPE) { try PEFile(data: Data(mz.bytes)) }
    }

    @Test func rejectsTruncatedHeaders() {
        let truncated = PEBuilder(imports: ["d3d11.dll"]).build().prefix(0x60)
        #expect(throws: PEFile.ParseError.truncated) { try PEFile(data: Data(truncated)) }
    }

    @Test func ignoresImportNamesOutsideTheFile() throws {
        var data = [UInt8](PEBuilder(imports: ["d3d11.dll"]).build())
        // Point the first import's Name RVA far outside every section.
        let descriptor = 0x200
        data.replaceSubrange((descriptor + 12)..<(descriptor + 16), with: [0xFF, 0xFF, 0xFF, 0x7F])
        let pe = try PEFile(data: Data(data))
        #expect(pe.imports.isEmpty)
    }
}
