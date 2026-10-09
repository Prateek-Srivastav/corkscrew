import Foundation

/// Bounds-checked reader for Windows PE/COFF executables.
///
/// Reads only what the launcher needs: CPU architecture, subsystem, and the DLLs
/// the binary imports (regular and delay-loaded). Never trusts offsets in the file.
public struct PEFile: Sendable, Equatable {
    public enum Machine: Sendable, Equatable, CustomStringConvertible {
        case i386, x86_64, arm64, armNT
        case other(UInt16)

        init(rawValue: UInt16) {
            switch rawValue {
            case 0x014C: self = .i386
            case 0x8664: self = .x86_64
            case 0xAA64: self = .arm64
            case 0x01C4: self = .armNT
            default: self = .other(rawValue)
            }
        }

        public var description: String {
            switch self {
            case .i386: "x86 (32-bit)"
            case .x86_64: "x64"
            case .arm64: "ARM64"
            case .armNT: "ARM (32-bit)"
            case .other(let raw): String(format: "unknown (0x%04X)", raw)
            }
        }
    }

    public enum Format: Sendable, Equatable { case pe32, pe32Plus }

    public enum ParseError: Error, Equatable {
        case notPE
        case truncated
        case unsupportedOptionalHeader(UInt16)
    }

    public let machine: Machine
    public let format: Format
    public let subsystem: UInt16
    public let isDLL: Bool
    /// True when the image has a CLR header, i.e. it needs .NET (wine-mono).
    public let isDotNet: Bool
    /// Lowercased DLL names from the import table, in file order.
    public let imports: [String]
    /// Lowercased DLL names from the delay-load import table, in file order.
    public let delayImports: [String]

    public var allImports: Set<String> { Set(imports).union(delayImports) }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        let headers = try Headers(data: data)
        let r = headers.image.reader
        let image = headers.image
        let imageBase = headers.imageBase
        machine = Machine(rawValue: try r.u16(headers.coff))
        format = headers.format
        isDLL = try r.u16(headers.coff + 18) & 0x2000 != 0
        subsystem = try r.u16(headers.optionalHeader + 68)

        isDotNet = image.directory(14) != nil

        var imports: [String] = []
        if let dir = image.directory(1), var entry = image.fileOffset(ofRVA: dir.rva) {
            // IMAGE_IMPORT_DESCRIPTOR: 20 bytes, terminated by an all-zero entry.
            for _ in 0..<4096 {
                guard let lookup = try? r.u32(entry), let nameRVA = try? r.u32(entry + 12),
                      let thunk = try? r.u32(entry + 16) else { break }
                if lookup == 0, nameRVA == 0, thunk == 0 { break }
                if let name = image.string(atRVA: nameRVA) { imports.append(name.lowercased()) }
                entry += 20
            }
        }
        self.imports = imports

        var delayImports: [String] = []
        if let dir = image.directory(13), var entry = image.fileOffset(ofRVA: dir.rva) {
            // ImgDelayDescr: 32 bytes. Bit 0 of Attributes means the fields are RVAs;
            // otherwise (old toolchains) they are virtual addresses.
            for _ in 0..<4096 {
                guard let attributes = try? r.u32(entry), let nameField = try? r.u32(entry + 4),
                      nameField != 0 else { break }
                let nameRVA = attributes & 1 == 1
                    ? nameField
                    : UInt32(truncatingIfNeeded: UInt64(nameField) &- imageBase)
                if let name = image.string(atRVA: nameRVA) { delayImports.append(name.lowercased()) }
                entry += 32
            }
        }
        self.delayImports = delayImports
    }
}

/// The headers every reader of a PE file needs: where things are, and the section table.
struct Headers {
    let coff: Int
    let optionalHeader: Int
    let format: PEFile.Format
    let imageBase: UInt64
    let image: Image

    init(data: Data) throws {
        let r = ByteReader(data: data)
        guard data.count >= 0x40, (try? r.u16(0)) == 0x5A4D else { throw PEFile.ParseError.notPE } // "MZ"
        let peOffset = Int(try r.u32(0x3C))
        guard (try? r.u32(peOffset)) == 0x0000_4550 else { throw PEFile.ParseError.notPE } // "PE\0\0"

        coff = peOffset + 4
        let sectionCount = Int(try r.u16(coff + 2))
        let optionalHeaderSize = Int(try r.u16(coff + 16))
        optionalHeader = coff + 20
        let magic = try r.u16(optionalHeader)
        let directoriesStart: Int
        switch magic {
        case 0x10B:
            format = .pe32
            directoriesStart = optionalHeader + 96
            imageBase = UInt64(try r.u32(optionalHeader + 28))
        case 0x20B:
            format = .pe32Plus
            directoriesStart = optionalHeader + 112
            imageBase = try r.u64(optionalHeader + 24)
        default:
            throw PEFile.ParseError.unsupportedOptionalHeader(magic)
        }
        let directoryCount = Int(try r.u32(directoriesStart - 4))

        let sectionTable = optionalHeader + optionalHeaderSize
        var sections: [Section] = []
        for index in 0..<min(sectionCount, 96) {
            let s = sectionTable + index * 40
            sections.append(Section(
                virtualSize: try r.u32(s + 8),
                virtualAddress: try r.u32(s + 12),
                rawSize: try r.u32(s + 16),
                rawOffset: try r.u32(s + 20)
            ))
        }
        image = Image(reader: r, sections: sections, directoriesStart: directoriesStart, directoryCount: directoryCount)
    }
}

struct Section {
    let virtualSize: UInt32
    let virtualAddress: UInt32
    let rawSize: UInt32
    let rawOffset: UInt32
}

struct Image {
    let reader: ByteReader
    let sections: [Section]
    let directoriesStart: Int
    let directoryCount: Int

    func directory(_ index: Int) -> (rva: UInt32, size: UInt32)? {
        guard index < directoryCount else { return nil }
        let entry = directoriesStart + index * 8
        guard let rva = try? reader.u32(entry), let size = try? reader.u32(entry + 4), rva != 0 else { return nil }
        return (rva, size)
    }

    func fileOffset(ofRVA rva: UInt32) -> Int? {
        for s in sections where rva >= s.virtualAddress {
            let delta = rva - s.virtualAddress
            guard delta < max(s.virtualSize, s.rawSize) else { continue }
            return delta < s.rawSize ? Int(s.rawOffset) + Int(delta) : nil // nil: zero-filled, not in file
        }
        // Headers are mapped 1:1 below the first section.
        if let first = sections.map(\.virtualAddress).min(), rva < first { return Int(rva) }
        return nil
    }

    func string(atRVA rva: UInt32) -> String? {
        fileOffset(ofRVA: rva).flatMap { try? reader.cString(at: $0) }
    }
}

struct ByteReader {
    let data: Data

    func u16(_ offset: Int) throws -> UInt16 { UInt16(littleEndian: try load(offset)) }
    func u32(_ offset: Int) throws -> UInt32 { UInt32(littleEndian: try load(offset)) }
    func u64(_ offset: Int) throws -> UInt64 { UInt64(littleEndian: try load(offset)) }

    /// NUL-terminated printable-ASCII string, as used for DLL names.
    func cString(at offset: Int, maxLength: Int = 256) throws -> String {
        guard offset >= 0, offset < data.count else { throw PEFile.ParseError.truncated }
        var bytes: [UInt8] = []
        var index = data.startIndex + offset
        while index < data.endIndex, bytes.count < maxLength {
            let byte = data[index]
            if byte == 0 { break }
            guard (0x20...0x7E).contains(byte) else { throw PEFile.ParseError.truncated }
            bytes.append(byte)
            index += 1
        }
        guard !bytes.isEmpty else { throw PEFile.ParseError.truncated }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func load<T: FixedWidthInteger>(_ offset: Int) throws -> T {
        guard offset >= 0, offset <= data.count - MemoryLayout<T>.size else { throw PEFile.ParseError.truncated }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }
}
