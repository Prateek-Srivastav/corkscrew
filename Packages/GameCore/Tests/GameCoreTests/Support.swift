import Foundation

/// Creates a fresh temporary folder, removed after `body` returns.
func withTempDir<T>(_ body: (URL) throws -> T) throws -> T {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "GameCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

/// `withTempDir` for async tests.
func withTempDir<T>(_ body: (URL) async throws -> T) async throws -> T {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "GameCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await body(dir)
}

extension URL {
    @discardableResult
    func makeDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }

    func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: self)
    }

    func write(_ text: String) throws { try write(Data(text.utf8)) }
}

/// Builds minimal valid PE images: one section holding the import tables, DLL names and a payload.
struct PEBuilder {
    var machine: UInt16 = 0x8664
    var pe32Plus = true
    var isDLL = false
    var dotNet = false
    var imports: [String] = []
    var delayImports: [String] = []
    /// Extra bytes in the section, e.g. a DLL name the program only passes to LoadLibrary.
    var payload: [UInt8] = []
    /// Resources by type (3 = icon, 14 = icon group), each with its numeric id and data.
    var resources: [UInt32: [(id: UInt32, data: [UInt8])]] = [:]

    func build() -> Data {
        let sectionRVA: UInt32 = 0x1000
        let sectionFileOffset = 0x200

        var section = Bytes()
        section.zeros((imports.count + 1) * 20)
        let delayTable = section.count
        if !delayImports.isEmpty { section.zeros((delayImports.count + 1) * 32) }
        for (index, name) in imports.enumerated() {
            let nameRVA = sectionRVA + UInt32(section.count)
            section.append(Array(name.utf8) + [0])
            section.put32(0x1000, at: index * 20)          // OriginalFirstThunk
            section.put32(nameRVA, at: index * 20 + 12)    // Name
            section.put32(0x1000, at: index * 20 + 16)     // FirstThunk
        }
        for (index, name) in delayImports.enumerated() {
            let nameRVA = sectionRVA + UInt32(section.count)
            section.append(Array(name.utf8) + [0])
            section.put32(1, at: delayTable + index * 32)  // Attributes: RVA-based
            section.put32(nameRVA, at: delayTable + index * 32 + 4)
        }
        section.append(payload)
        var resourceDirectory: (rva: UInt32, size: UInt32)?
        if !resources.isEmpty {
            section.pad(to: 4)
            let rva = sectionRVA + UInt32(section.count)
            let tree = resourceTree(rva: rva)
            section.append(tree)
            resourceDirectory = (rva, UInt32(tree.count))
        }
        section.pad(to: 0x200)

        var file = Bytes()
        file.zeros(sectionFileOffset)
        file.put16(0x5A4D, at: 0)                          // "MZ"
        file.put32(0x40, at: 0x3C)                         // e_lfanew
        file.put32(0x0000_4550, at: 0x40)                  // "PE\0\0"
        let coff = 0x44
        let optionalSize = pe32Plus ? 240 : 224
        file.put16(machine, at: coff)
        file.put16(1, at: coff + 2)                        // NumberOfSections
        file.put16(UInt16(optionalSize), at: coff + 16)
        file.put16(isDLL ? 0x2022 : 0x0022, at: coff + 18)
        let opt = coff + 20
        file.put16(pe32Plus ? 0x20B : 0x10B, at: opt)
        if pe32Plus { file.put64(0x1_4000_0000, at: opt + 24) } else { file.put32(0x40_0000, at: opt + 28) }
        file.put16(3, at: opt + 68)                        // console subsystem
        let directories = opt + (pe32Plus ? 112 : 96)
        file.put32(16, at: directories - 4)                // NumberOfRvaAndSizes
        if !imports.isEmpty {
            file.put32(sectionRVA, at: directories + 8)
            file.put32(UInt32((imports.count + 1) * 20), at: directories + 12)
        }
        if let resourceDirectory {
            file.put32(resourceDirectory.rva, at: directories + 2 * 8)
            file.put32(resourceDirectory.size, at: directories + 2 * 8 + 4)
        }
        if !delayImports.isEmpty {
            file.put32(sectionRVA + UInt32(delayTable), at: directories + 13 * 8)
            file.put32(UInt32((delayImports.count + 1) * 32), at: directories + 13 * 8 + 4)
        }
        if dotNet {
            file.put32(sectionRVA, at: directories + 14 * 8)
            file.put32(72, at: directories + 14 * 8 + 4)
        }
        let header = opt + optionalSize
        file.putBytes(Array(".idata".utf8), at: header)
        file.put32(UInt32(section.count), at: header + 8)  // VirtualSize
        file.put32(sectionRVA, at: header + 12)            // VirtualAddress
        file.put32(UInt32(section.count), at: header + 16) // SizeOfRawData
        file.put32(UInt32(sectionFileOffset), at: header + 20)
        file.append(section.bytes)
        return Data(file.bytes)
    }
}

extension PEBuilder {
    /// The type → id → language (0) directory tree, then data entries, then the data.
    private func resourceTree(rva: UInt32) -> [UInt8] {
        let types = resources.keys.sorted()
        let items = types.flatMap { type in resources[type]!.sorted { $0.id < $1.id }.map { (type: type, id: $0.id, data: $0.data) } }
        var offset = 16 + 8 * types.count
        var typeDirectories: [Int] = []
        for type in types { typeDirectories.append(offset); offset += 16 + 8 * resources[type]!.count }
        let languageDirectories = items.indices.map { offset + $0 * 24 }
        offset += items.count * 24
        let dataEntries = items.indices.map { offset + $0 * 16 }
        offset += items.count * 16
        var blobs: [Int] = []
        for item in items { blobs.append(offset); offset += (item.data.count + 3) / 4 * 4 }

        var tree = Bytes()
        tree.zeros(offset)
        tree.put16(UInt16(types.count), at: 14)
        var index = 0
        for (t, type) in types.enumerated() {
            tree.put32(type, at: 16 + t * 8)
            tree.put32(0x8000_0000 | UInt32(typeDirectories[t]), at: 16 + t * 8 + 4)
            let count = resources[type]!.count
            tree.put16(UInt16(count), at: typeDirectories[t] + 14)
            for n in 0..<count {
                let item = items[index]
                let entry = typeDirectories[t] + 16 + n * 8
                tree.put32(item.id, at: entry)
                tree.put32(0x8000_0000 | UInt32(languageDirectories[index]), at: entry + 4)
                tree.put16(1, at: languageDirectories[index] + 14)
                tree.put32(0, at: languageDirectories[index] + 16)  // language neutral
                tree.put32(UInt32(dataEntries[index]), at: languageDirectories[index] + 20)
                tree.put32(rva + UInt32(blobs[index]), at: dataEntries[index])
                tree.put32(UInt32(item.data.count), at: dataEntries[index] + 4)
                tree.putBytes(item.data, at: blobs[index])
                index += 1
            }
        }
        return tree.bytes
    }

    /// A GRPICONDIR naming the given RT_ICON ids, each claiming `width`×`width` pixels.
    static func iconGroup(_ icons: [(id: UInt16, width: UInt8, size: Int)]) -> [UInt8] {
        var group = Bytes()
        group.zeros(6 + icons.count * 14)
        group.put16(1, at: 2)
        group.put16(UInt16(icons.count), at: 4)
        for (index, icon) in icons.enumerated() {
            let entry = 6 + index * 14
            group.putBytes([icon.width, icon.width], at: entry)
            group.put16(1, at: entry + 4)                      // planes
            group.put16(32, at: entry + 6)                     // bits per pixel
            group.put32(UInt32(icon.size), at: entry + 8)
            group.put16(icon.id, at: entry + 12)
        }
        return group.bytes
    }
}

struct Bytes {
    var bytes: [UInt8] = []
    var count: Int { bytes.count }

    mutating func zeros(_ n: Int) { bytes += Array(repeating: 0, count: n) }
    mutating func append(_ more: [UInt8]) { bytes += more }
    mutating func pad(to alignment: Int) {
        if bytes.count % alignment != 0 { zeros(alignment - bytes.count % alignment) }
    }
    mutating func put16(_ value: UInt16, at offset: Int) { put(UInt64(value), width: 2, at: offset) }
    mutating func put32(_ value: UInt32, at offset: Int) { put(UInt64(value), width: 4, at: offset) }
    mutating func put64(_ value: UInt64, at offset: Int) { put(value, width: 8, at: offset) }
    mutating func putBytes(_ more: [UInt8], at offset: Int) {
        for (index, byte) in more.enumerated() { bytes[offset + index] = byte }
    }

    private mutating func put(_ value: UInt64, width: Int, at offset: Int) {
        for index in 0..<width { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(index))) }
    }
}

func utf16LE(_ text: String) -> [UInt8] { Array(text.utf8).flatMap { [$0, 0] } }
