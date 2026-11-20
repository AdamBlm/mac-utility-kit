import Darwin
import Foundation
import ImageIO

public struct BatchRenameRule: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case replace = "Find and replace", capitalization = "Change case", number = "Numbering", date = "Date"
    }

    public enum Capitalization: String, CaseIterable, Sendable {
        case lowercase = "lowercase", uppercase = "UPPERCASE", title = "Title Case"
    }

    public enum DateSource: String, CaseIterable, Sendable {
        case created = "Created", modified = "Modified", current = "Today", captured = "Photo capture date"
    }

    public enum Placement: String, CaseIterable, Sendable {
        case prefix = "Prefix", suffix = "Suffix"
    }

    public let id = UUID()
    public var kind: Kind = .replace
    public var search = ""
    public var replacement = ""
    public var caseSensitive = true
    public var regularExpression = false
    public var capitalization: Capitalization = .lowercase
    public var start = 1
    public var increment = 1
    public var padding = 2
    public var dateSource: DateSource = .modified
    public var dateFormat = "yyyy-MM-dd"
    public var placement: Placement = .suffix
    public var separator = "-"

    public init(kind: Kind = .replace) { self.kind = kind }
}

public struct BatchRenameOptions: Equatable, Sendable {
    public enum NumberingOrder: String, CaseIterable, Identifiable, Sendable {
        case queue = "Queue order"
        case nameAscending = "Name ascending"
        case nameDescending = "Name descending"

        public var id: Self { self }

        fileprivate func order(_ files: [URL]) -> [URL] {
            guard self != .queue else { return files }
            return files.sorted { first, second in
                let names = first.lastPathComponent.localizedStandardCompare(second.lastPathComponent)
                if names == .orderedSame { return first.path.utf8.lexicographicallyPrecedes(second.path.utf8) }
                return names == (self == .nameAscending ? .orderedAscending : .orderedDescending)
            }
        }
    }

    public var numberingOrder = NumberingOrder.queue
    public var includesExtension = false
    public var rules = [BatchRenameRule()]

    public init() {}
}

public struct BatchRenameChange: Equatable, Sendable {
    public let source: URL
    public let destination: URL
}

public struct BatchRenameReceipt: Sendable {
    fileprivate let moves: [BatchRename.Move]

    public func undo() throws {
        try BatchRename.execute(moves.map { BatchRename.Move(source: $0.destination, destination: $0.source, identity: $0.identity) })
    }
}

public enum BatchRenameError: LocalizedError {
    case invalidName(String)
    case conflict(String)
    case missingDate(String)
    case missingCaptureDate(String)
    case missingCaptureOffset(String)
    case invalidCounter
    case missingFile(String)
    case changedFile(String)
    case changedCaptureSource(String)
    case changedFileDate(String)
    case interrupted(String, [String])

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name): "Invalid filename: “\(name)”"
        case .conflict(let name): "The filename “\(name)” is already in use."
        case .missingDate(let name): "The selected file date is unavailable for “\(name)”."
        case .missingCaptureDate(let name): "“\(name)” has no readable original EXIF capture date."
        case .missingCaptureOffset(let name): "“\(name)” has no original EXIF time-zone offset. Remove the time-zone field from the date format."
        case .invalidCounter: "The numbering range is too large."
        case .missingFile(let name): "“\(name)” is missing or is a folder."
        case .changedFile(let name): "“\(name)” was replaced after the rename was planned."
        case .changedCaptureSource(let name): "“\(name)” changed after its capture date was read. Review a new rename preview."
        case .changedFileDate(let name): "The selected file date for “\(name)” changed. Review a new rename preview."
        case .interrupted(let cause, let recovery):
            recovery.isEmpty
                ? "Rename stopped. Original filenames were restored. \(cause)"
                : "Rename stopped. \(cause) Files requiring manual recovery:\n\(recovery.joined(separator: "\n"))"
        }
    }
}

public struct BatchRenamePlan: Sendable {
    public let changes: [BatchRenameChange]
    fileprivate let moves: [BatchRename.Move]
    fileprivate let captureSources: [(file: URL, stamp: DuplicateFileStamp)]
    fileprivate let fileDates: [(file: URL, key: FileAttributeKey, date: Date)]

    public func apply() throws -> BatchRenameReceipt {
        for (file, stamp) in captureSources where (try? DuplicateFileIO.inspect(file)) != stamp {
            throw BatchRenameError.changedCaptureSource(file.lastPathComponent)
        }
        for (file, key, date) in fileDates {
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes?[key] as? Date == date else {
                throw BatchRenameError.changedFileDate(file.lastPathComponent)
            }
        }
        try BatchRename.execute(moves)
        return BatchRenameReceipt(moves: moves)
    }
}

public enum BatchRename {
    fileprivate struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t

        init(_ url: URL) throws {
            var file = stat()
            guard url.isFileURL, lstat(url.path, &file) == 0, (file.st_mode & S_IFMT) != S_IFDIR else {
                throw BatchRenameError.missingFile(url.lastPathComponent)
            }
            device = file.st_dev
            inode = file.st_ino
        }
    }

    fileprivate struct Move: Sendable {
        let source: URL
        let destination: URL
        let identity: FileIdentity
    }

    public static func plan(files: [URL], options: BatchRenameOptions, now: Date = .now) throws -> BatchRenamePlan {
        let rules = try options.rules.map { rule in
            let regex = rule.kind == .replace && rule.regularExpression && !rule.search.isEmpty
                ? try NSRegularExpression(pattern: rule.search, options: rule.caseSensitive ? [] : .caseInsensitive)
                : nil
            return (rule, regex)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        let localTimeZone = TimeZone.current
        var changes: [BatchRenameChange] = []
        var moves: [Move] = []
        var captureSources: [(file: URL, stamp: DuplicateFileStamp)] = []
        var fileDates: [(file: URL, key: FileAttributeKey, date: Date)] = []
        let orderedFiles = options.rules.contains { $0.kind == .number } ? options.numberingOrder.order(files) : files
        for (index, input) in orderedFiles.enumerated() {
            guard input.isFileURL else { throw BatchRenameError.missingFile(input.lastPathComponent) }
            let parent = input.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            let source = parent.appendingPathComponent(input.lastPathComponent)
            let identity = try FileIdentity(source)
            let original = source.lastPathComponent
            var captured: (date: Date, timeZone: TimeZone?)?
            var attributes: [FileAttributeKey: Any]?
            var collectedDates: [FileAttributeKey: Date] = [:]
            let ext = options.includesExtension ? "" : source.pathExtension
            var name = ext.isEmpty ? original : source.deletingPathExtension().lastPathComponent
            for (rule, regex) in rules {
                switch rule.kind {
                case .replace:
                    guard !rule.search.isEmpty else { continue }
                    name = regex?.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: rule.replacement)
                        ?? name.replacingOccurrences(of: rule.search, with: rule.replacement, options: rule.caseSensitive ? .literal : [.literal, .caseInsensitive])
                case .capitalization:
                    switch rule.capitalization {
                    case .lowercase: name = name.lowercased()
                    case .uppercase: name = name.uppercased()
                    case .title: name = name.capitalized
                    }
                case .number:
                    let (offset, overflowOffset) = index.multipliedReportingOverflow(by: rule.increment)
                    let (value, overflowValue) = rule.start.addingReportingOverflow(offset)
                    guard !overflowOffset, !overflowValue else { throw BatchRenameError.invalidCounter }
                    let digits = String(value.magnitude)
                    let sign = value < 0 ? "-" : ""
                    let zeros = String(repeating: "0", count: max(0, min(rule.padding, 32) - digits.count - sign.count))
                    name = decorate(name, with: sign + zeros + digits, using: rule)
                case .date:
                    let date: Date?
                    formatter.timeZone = localTimeZone
                    switch rule.dateSource {
                    case .current:
                        date = now
                    case .created, .modified:
                        if attributes == nil { attributes = try FileManager.default.attributesOfItem(atPath: source.path) }
                        let key: FileAttributeKey = rule.dateSource == .created ? .creationDate : .modificationDate
                        date = attributes?[key] as? Date
                        collectedDates[key] = date
                    case .captured:
                        if captured == nil {
                            guard let stamp = try? DuplicateFileIO.inspect(source), let capture = captureDate(source) else {
                                throw BatchRenameError.missingCaptureDate(original)
                            }
                            guard (try? DuplicateFileIO.inspect(source)) == stamp else {
                                throw BatchRenameError.changedCaptureSource(original)
                            }
                            captured = capture
                            captureSources.append((source, stamp))
                        }
                        guard let capture = captured else { throw BatchRenameError.missingCaptureDate(original) }
                        if capture.timeZone == nil, usesTimeZone(rule.dateFormat) {
                            throw BatchRenameError.missingCaptureOffset(original)
                        }
                        date = capture.date
                        formatter.timeZone = capture.timeZone ?? .gmt
                    }
                    guard let date else { throw BatchRenameError.missingDate(original) }
                    formatter.dateFormat = rule.dateFormat
                    name = decorate(name, with: formatter.string(from: date), using: rule)
                }
            }
            guard !name.isEmpty else { throw BatchRenameError.invalidName(name) }
            if !ext.isEmpty { name += "." + ext }
            guard name != ".", name != "..", !name.contains("/"), !name.contains("\0"), name.utf8.count <= 255 else {
                throw BatchRenameError.invalidName(name)
            }
            let destination = parent.appendingPathComponent(name)
            fileDates.append(contentsOf: collectedDates.map { (source, $0.key, $0.value) })
            changes.append(BatchRenameChange(source: source, destination: destination))
            if Array(original.utf8) != Array(name.utf8) {
                moves.append(Move(source: source, destination: destination, identity: identity))
            }
        }
        try validate(moves)
        return BatchRenamePlan(changes: changes, moves: moves, captureSources: captureSources, fileDates: fileDates)
    }

    private static func captureDate(_ file: URL) -> (date: Date, timeZone: TimeZone?)? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let stamp = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String else { return nil }

        let offset = exif[kCGImagePropertyExifOffsetTimeOriginal as String]
        let timeZone: TimeZone?
        if let offset {
            guard let text = offset as? String,
                  let match = text.wholeMatch(of: /([+-])([0-9]{2}):([0-5][0-9])/),
                  let hours = Int(match.2), let minutes = Int(match.3),
                  let zone = TimeZone(secondsFromGMT: (match.1 == "-" ? -1 : 1) * (hours * 3_600 + minutes * 60)) else {
                return nil
            }
            timeZone = zone
        } else {
            timeZone = nil
        }

        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .gregorian)
        // An offset-less EXIF date is a wall-clock value. A fixed zone preserves its fields
        // even at local DST transitions, and callers reject patterns that would print that zone.
        parser.timeZone = timeZone ?? .gmt
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        parser.isLenient = false
        guard let date = parser.date(from: stamp), parser.string(from: date) == stamp else { return nil }
        return (date, timeZone)
    }

    private static func usesTimeZone(_ pattern: String) -> Bool {
        var quoted = false
        for character in pattern {
            if character == "'" { quoted.toggle() }
            else if !quoted, "zZOvVXx".contains(character) { return true }
        }
        return false
    }

    private static func decorate(_ name: String, with value: String, using rule: BatchRenameRule) -> String {
        switch rule.placement {
        case .prefix: value + rule.separator + name
        case .suffix: name + rule.separator + value
        }
    }

    private struct DirectoryNames {
        let caseSensitive: Bool
        let existing: Set<String>
        var sources: Set<String> = []
        var destinations: Set<String> = []

        init(_ parent: URL) throws {
            caseSensitive = try parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == true
            let contents = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            existing = Set(contents.map { [caseSensitive] in Self.key($0, caseSensitive: caseSensitive) })
        }

        func key(_ url: URL) -> String {
            Self.key(url.lastPathComponent, caseSensitive: caseSensitive)
        }

        private static func key(_ name: String, caseSensitive: Bool) -> String {
            if caseSensitive { return name }
            return name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        }

        mutating func insert(_ move: Move) throws {
            guard sources.insert(key(move.source)).inserted, destinations.insert(key(move.destination)).inserted else {
                throw BatchRenameError.conflict(move.destination.lastPathComponent)
            }
        }
    }

    private static func validate(_ moves: [Move]) throws {
        for (parent, group) in Dictionary(grouping: moves, by: { $0.source.deletingLastPathComponent() }) {
            var names = try DirectoryNames(parent)
            for move in group {
                guard try FileIdentity(move.source) == move.identity else {
                    throw BatchRenameError.changedFile(move.source.lastPathComponent)
                }
                try names.insert(move)
            }
            if let conflict = group.first(where: {
                let key = names.key($0.destination)
                return names.existing.contains(key) && !names.sources.contains(key)
            }) {
                throw BatchRenameError.conflict(conflict.destination.lastPathComponent)
            }
        }
    }

    fileprivate static func execute(_ moves: [Move]) throws {
        try validate(moves)
        var staged: [(move: Move, url: URL)] = []
        var published = 0
        do {
            for move in moves {
                let temp = move.source.deletingLastPathComponent().appendingPathComponent(".MacUtilityKit-\(UUID().uuidString)")
                try relocate(move.source, temp, identity: move.identity)
                staged.append((move, temp))
            }
            for entry in staged {
                try relocate(entry.url, entry.move.destination, identity: entry.move.identity)
                published += 1
            }
        } catch {
            var recovery: [String] = []
            var unstaged = Set<URL>()
            for entry in staged.prefix(published).reversed() {
                do { try relocate(entry.move.destination, entry.url, identity: entry.move.identity) }
                catch {
                    unstaged.insert(entry.url)
                    recovery.append("\(entry.move.destination.path) → \(entry.move.source.path)")
                }
            }
            for entry in staged.reversed() where !unstaged.contains(entry.url) {
                do { try relocate(entry.url, entry.move.source, identity: entry.move.identity) }
                catch { recovery.append("\(entry.url.path) → \(entry.move.source.path)") }
            }
            throw BatchRenameError.interrupted(error.localizedDescription, recovery)
        }
    }

    private static func relocate(_ source: URL, _ destination: URL, identity: FileIdentity) throws {
        guard try FileIdentity(source) == identity else { throw BatchRenameError.changedFile(source.lastPathComponent) }
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSFilePathErrorKey: destination.path,
                NSLocalizedDescriptionKey: "Could not rename “\(source.lastPathComponent)” to “\(destination.lastPathComponent)”. \(String(cString: strerror(code)))"
            ])
        }
    }
}
