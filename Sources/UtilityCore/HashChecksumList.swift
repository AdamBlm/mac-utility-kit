import Foundation

package struct HashChecksumList: Sendable {
    private static let maximumBytes = 512 * 1024

    package enum Expectation: Equatable, Sendable {
        case digest(String), missing, ambiguous
    }

    private struct Entry: Sendable {
        let name: Data
        let digest: String
    }

    private let entriesByBasename: [Data: [Entry]]

    package init(_ text: String, algorithm: HashAlgorithm) throws {
        guard text.utf8.count <= Self.maximumBytes else {
            throw ToolError.invalid("Enter a checksum list up to 512 KiB.")
        }
        var entries: [Data: [Entry]] = [:]
        for (index, rawLine) in text.utf8.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
            var line = Array(rawLine.last == 13 ? rawLine.dropLast() : rawLine[...])
            guard !line.isEmpty else { continue }
            let escaped = line.first == 92
            if escaped { line.removeFirst() }
            let width = algorithm.hexLength
            guard line.count > width + 2,
                  HashGenerator.isHexDigest(line.prefix(width), algorithm: algorithm),
                  line[width] == 32, line[width + 1] == 32 || line[width + 1] == 42,
                  let name = Self.filename(line[(width + 2)...], escaped: escaped), !name.isEmpty,
                  let basename = name.split(separator: 47, omittingEmptySubsequences: false).last, !basename.isEmpty else {
                throw ToolError.invalid("Invalid \(algorithm.rawValue) checksum on line \(index + 1).")
            }
            let digest = String(decoding: line.prefix(width), as: UTF8.self).lowercased()
            entries[Data(basename), default: []].append(Entry(name: name, digest: digest))
        }
        guard !entries.isEmpty else { throw ToolError.invalid("Enter at least one checksum and filename.") }
        entriesByBasename = entries
    }

    package static func usesAbsolutePaths(for files: [URL]) -> Bool {
        Set(files.map { $0.standardizedFileURL.deletingLastPathComponent() }).count > 1
            || Set(files.map { Data($0.lastPathComponent.utf8) }).count < files.count
    }

    package static func format(_ digests: [String], for files: [URL], algorithm: HashAlgorithm) throws -> String {
        guard !files.isEmpty, files.count == digests.count else {
            throw ToolError.invalid("Hash every selected file before exporting a checksum list.")
        }
        let absolute = usesAbsolutePaths(for: files)
        var result = Data()
        for (file, digest) in zip(files, digests) {
            guard HashGenerator.isHexDigest(digest.utf8, algorithm: algorithm) else {
                throw ToolError.invalid("Hash every selected file before exporting a checksum list.")
            }
            let path = absolute ? file.standardizedFileURL.path : file.lastPathComponent
            result.append(checksumLine(digest, path: path, binary: true))
            guard result.count <= maximumBytes else {
                throw ToolError.invalid("Export fewer files to keep the checksum list within 512 KiB.")
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    package static func checksumLine(_ digest: String, path: String, binary: Bool) -> Data {
        var result = Data()
        let escapes = path.utf8.contains { $0 == 92 || $0 == 10 || $0 == 13 }
        if escapes { result.append(92) }
        result.append(contentsOf: digest.utf8)
        result.append(contentsOf: [32, binary ? 42 : 32])
        for byte in path.utf8 {
            switch byte {
            case 92: result.append(contentsOf: [92, 92])
            case 10: result.append(contentsOf: [92, 110])
            case 13: result.append(contentsOf: [92, 114])
            default: result.append(byte)
            }
        }
        result.append(10)
        return result
    }

    package func expectations(for files: [URL]) -> [Expectation] {
        let candidates = Dictionary(grouping: files.indices) { Data(files[$0].lastPathComponent.utf8) }
        let paths = files.map { Data($0.standardizedFileURL.path.utf8) }
        var matched = Array(repeating: Expectation.missing, count: files.count)
        for (basename, entries) in entriesByBasename {
            guard let indexes = candidates[basename] else { continue }
            for entry in entries {
                let choices = indexes.filter { Self.matches(entry.name, path: paths[$0]) }
                for index in choices {
                    let expected = Expectation.digest(entry.digest)
                    if choices.count == 1, matched[index] == .missing || matched[index] == expected {
                        matched[index] = expected
                    } else {
                        matched[index] = .ambiguous
                    }
                }
            }
        }
        return matched
    }

    private static func matches(_ name: Data, path: Data) -> Bool {
        if name.first == 47 { return name == path }
        var relative = name[...]
        while relative.starts(with: [46, 47]) { relative = relative.dropFirst(2) }
        return !relative.isEmpty && path.count > relative.count
            && path[path.endIndex - relative.count - 1] == 47
            && path.suffix(relative.count).elementsEqual(relative)
    }

    private static func filename(_ bytes: ArraySlice<UInt8>, escaped: Bool) -> Data? {
        guard !bytes.contains(0) else { return nil }
        if !escaped { return Data(bytes) }
        var result = Data()
        var escaping = false
        for byte in bytes {
            if escaping {
                switch byte {
                case 92: result.append(92)
                case 110: result.append(10)
                case 114: result.append(13)
                default: return nil
                }
                escaping = false
            } else if byte == 92 {
                escaping = true
            } else {
                result.append(byte)
            }
        }
        return escaping ? nil : result
    }
}
