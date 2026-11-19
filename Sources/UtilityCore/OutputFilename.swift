import Foundation

enum OutputFilename {
    // Foundation file operations can normalize components to decomposed UTF-8.
    private static let byteLimit = 255

    static func fits(_ name: String) -> Bool {
        byteCount(name) <= byteLimit
    }

    static func numberedSource(_ input: URL, position: Int, suffix: String = "") -> String {
        let stem = "\(position) - \(input.deletingPathExtension().lastPathComponent)"
        return shortenedStem(stem, suffix: suffix) + suffix
    }

    static func shortenedStem(_ stem: String, suffix: String) -> String {
        guard !fits(stem + suffix) else { return stem }

        var remaining = byteLimit - byteCount(suffix)
        return String(stem.prefix { character in
            remaining -= byteCount(String(character))
            return remaining >= 0
        })
    }

    private static func byteCount(_ name: String) -> Int {
        name.decomposedStringWithCanonicalMapping.utf8.count
    }
}
