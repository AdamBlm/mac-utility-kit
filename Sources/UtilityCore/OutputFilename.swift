import Foundation

enum OutputFilename {
    // Foundation file operations can normalize components to decomposed UTF-8.
    private static let byteLimit = 255

    static func fits(_ name: String) -> Bool {
        byteCount(name) <= byteLimit
    }

    static func numberedSource(_ input: URL, position: Int, suffix: String = "") -> String {
        let prefix = "\(position) - "
        let stem = input.deletingPathExtension().lastPathComponent
        let name = prefix + stem + suffix
        guard !fits(name) else { return name }

        var remaining = byteLimit - byteCount(prefix) - byteCount(suffix)
        let shortened = stem.prefix { character in
            remaining -= byteCount(String(character))
            return remaining >= 0
        }
        return prefix + shortened + suffix
    }

    private static func byteCount(_ name: String) -> Int {
        name.decomposedStringWithCanonicalMapping.utf8.count
    }
}
