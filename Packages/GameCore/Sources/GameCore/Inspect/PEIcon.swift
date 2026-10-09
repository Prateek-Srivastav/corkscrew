import Foundation

extension PEFile {
    /// The program's icon as `.ico` file data (which `NSImage` reads), or nil when it has none.
    ///
    /// Uses the first icon group in the resources, as Windows Explorer does, with every size in it.
    /// Like the rest of the parser, it never trusts offsets or counts in the file.
    public static func icon(contentsOf url: URL) throws -> Data? {
        try icon(in: Data(contentsOf: url, options: .alwaysMapped))
    }

    public static func icon(in data: Data) throws -> Data? {
        let image = try Headers(data: data).image
        guard let directory = image.directory(2), let root = image.fileOffset(ofRVA: directory.rva) else { return nil }
        let resources = ResourceTree(image: image, base: root)

        guard let groups = resources.subdirectory(in: root, id: ResourceTree.groupIcon),
              let groupEntry = resources.entries(in: groups).first,
              let group = resources.firstData(of: groupEntry),
              let icons = resources.subdirectory(in: root, id: ResourceTree.icon)
        else { return nil }

        // GRPICONDIR: reserved, type (1 = icon), count; then 14-byte entries ending in the RT_ICON id.
        let r = image.reader
        guard group.count >= 6, (try? r.u16(group.offset + 2)) == 1, let count = try? r.u16(group.offset + 4) else { return nil }
        var entries: [(header: Data, image: Data)] = []
        for index in 0..<Int(min(count, 64)) {
            let entry = group.offset + 6 + index * 14
            guard entry + 14 <= group.offset + group.count, let id = try? r.u16(entry + 12),
                  let iconEntry = resources.entries(in: icons).first(where: { $0.id == UInt32(id) }),
                  let bitmap = resources.firstData(of: iconEntry)
            else { continue }
            // The first 12 bytes (size, colours, planes, bit depth, byte count) are the same in an .ico file.
            entries.append((r.data.subdata(in: r.range(entry, 12)), r.data.subdata(in: r.range(bitmap.offset, bitmap.count))))
        }
        guard !entries.isEmpty else { return nil }

        // ICONDIR, then 16-byte ICONDIRENTRYs (the 12 bytes above plus the image's file offset), then the images.
        var ico = Data()
        ico.appendLE(UInt16(0))
        ico.appendLE(UInt16(1))
        ico.appendLE(UInt16(entries.count))
        var offset = 6 + entries.count * 16
        for entry in entries {
            var header = entry.header
            header.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(entry.image.count).littleEndian) { Data($0) })
            ico.append(header)
            ico.appendLE(UInt32(offset))
            offset += entry.image.count
        }
        for entry in entries { ico.append(entry.image) }
        return ico
    }
}

/// The three-level resource directory (type → name → language) of a PE image.
private struct ResourceTree {
    static let icon: UInt32 = 3
    static let groupIcon: UInt32 = 14
    /// Icons are small; anything bigger than this is a damaged or hostile file.
    static let maxDataSize = 8 << 20

    struct Entry {
        /// The numeric id, or nil for a named entry.
        let id: UInt32?
        let target: UInt32
        var isDirectory: Bool { target & 0x8000_0000 != 0 }
    }

    let image: Image
    /// File offset of the resource section's root directory; directory offsets are relative to it.
    let base: Int

    func entries(in directory: Int) -> [Entry] {
        let r = image.reader
        guard let named = try? r.u16(directory + 12), let ids = try? r.u16(directory + 14) else { return [] }
        return (0..<min(Int(named) + Int(ids), 4096)).compactMap { index in
            let entry = directory + 16 + index * 8
            guard let name = try? r.u32(entry), let target = try? r.u32(entry + 4) else { return nil }
            return Entry(id: name & 0x8000_0000 == 0 ? name : nil, target: target)
        }
    }

    func subdirectory(in directory: Int, id: UInt32) -> Int? {
        entries(in: directory).first { $0.id == id && $0.isDirectory }.map { offset(of: $0) }
    }

    /// The data of the first language below a name entry: (file offset, byte count).
    func firstData(of entry: Entry) -> (offset: Int, count: Int)? {
        var entry = entry
        // Name → language → data; never follow more levels than that.
        for _ in 0..<2 where entry.isDirectory {
            guard let next = entries(in: offset(of: entry)).first else { return nil }
            entry = next
        }
        guard !entry.isDirectory else { return nil }
        let r = image.reader
        let leaf = offset(of: entry)
        guard let rva = try? r.u32(leaf), let size = try? r.u32(leaf + 4), size > 0, Int(size) <= Self.maxDataSize,
              let start = image.fileOffset(ofRVA: rva), start + Int(size) <= r.data.count
        else { return nil }
        return (start, Int(size))
    }

    private func offset(of entry: Entry) -> Int { base + Int(entry.target & 0x7FFF_FFFF) }
}

extension ByteReader {
    /// The data indices of `count` bytes at `offset`; callers check the bounds first.
    func range(_ offset: Int, _ count: Int) -> Range<Data.Index> {
        (data.startIndex + offset)..<(data.startIndex + offset + count)
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
