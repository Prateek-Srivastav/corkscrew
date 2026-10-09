import Foundation

/// Read-only access to a prefix's registry files (`user.reg`, `system.reg`).
///
/// The files are what wineserver last saved, which can lag its in-memory registry by a few seconds
/// while the bottle runs. Writes always go through `wine reg`, never through these files.
public enum WineRegistry {
    /// The raw data of value `name` under `key` (e.g. `Software\Wine\Mac Driver`): the text between
    /// the quotes for strings, `dword:0000001` and the like for everything else. Names and keys
    /// compare case-insensitively, as in Windows.
    public static func value(_ name: String, inKey key: String, file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return value(name, inKey: key, text: text)
    }

    static func value(_ name: String, inKey key: String, text: String) -> String? {
        // Section headers escape backslashes: [Software\\Wine\\Mac Driver] 1791375602
        let header = "[" + key.replacingOccurrences(of: #"\"#, with: #"\\"#).lowercased() + "]"
        let wanted = "\"" + name.lowercased() + "\"="
        var inKey = false
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("[") {
                inKey = line.lowercased().hasPrefix(header)
            } else if inKey, line.lowercased().hasPrefix(wanted) {
                let data = line.dropFirst(wanted.count)
                return data.hasPrefix("\"") && data.hasSuffix("\"") && data.count >= 2
                    ? String(data.dropFirst().dropLast()) : String(data)
            }
        }
        return nil
    }

    /// Wine's own reading of an on/off string option (`IS_OPTION_TRUE` in winemac.drv).
    static func isTrue(_ data: String?) -> Bool {
        guard let first = data?.first else { return false }
        return "yYtT1".contains(first)
    }
}
