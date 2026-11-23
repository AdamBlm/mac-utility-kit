import Foundation

package struct BatchFindReplaceOptions: Equatable, Sendable {
    package var pattern = ""
    package var replacement = ""
    package var regularExpression = false
    package var ignoresCase = false

    package init() {}

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.regularExpression == rhs.regularExpression && lhs.ignoresCase == rhs.ignoresCase
            && lhs.pattern.utf8.elementsEqual(rhs.pattern.utf8)
            && lhs.replacement.utf8.elementsEqual(rhs.replacement.utf8)
    }
}

package enum BatchFindReplace {
    package static let maximumFiles = 32
    private static let maximumFileBytes = 1_048_576
    private static let maximumBatchOutput = 16_777_216

    package struct File: Identifiable, Sendable {
        package let id: Int
        package let source: URL
        package let count: Int
        package let before: String
        package let after: String
        package let error: String?
        let version: PlainTextDecoding.FileVersion?
        let output: Data?

        package var changed: Bool { output != nil }
    }

    @concurrent
    package static func preview(_ inputs: [URL], options: BatchFindReplaceOptions) async throws -> [File] {
        guard (1...maximumFiles).contains(inputs.count) else {
            throw ToolError.invalid("Choose between 1 and \(maximumFiles) text files.")
        }
        guard !options.pattern.isEmpty else { throw ToolError.invalid("Enter text or a pattern to find.") }
        guard options.pattern.utf16.count <= 4_096, options.replacement.utf16.count <= 4_096 else {
            throw ToolError.invalid("Use up to 4,096 UTF-16 units in the search and replacement.")
        }
        var regexOptions = RegexTesterOptions()
        regexOptions.ignoresCase = options.ignoresCase
        if options.regularExpression {
            _ = try RegexTester.evaluate(
                pattern: options.pattern, sample: "", replacement: options.replacement, options: regexOptions
            )
        }
        var files: [File] = []
        var outputBytes = 0
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            do {
                let loaded = try await PlainTextDecoding.loadVerifiedFile(input, maximumBytes: maximumFileBytes)
                let format = PlainTextDecoding.Format(detecting: loaded.bytes)
                guard let text = format.decode(loaded.bytes) else {
                    throw ToolError.invalid("Choose UTF-8 or BOM-marked Unicode text.")
                }
                let result: (text: String, count: Int)
                if options.regularExpression {
                    let evaluation = try RegexTester.evaluate(
                        pattern: options.pattern, sample: text, replacement: options.replacement, options: regexOptions
                    )
                    result = (evaluation.replacement ?? text, evaluation.matches.count)
                } else {
                    result = try replaceLiterally(text, options: options)
                }
                var output: Data?
                if !text.utf8.elementsEqual(result.text.utf8) {
                    guard let encoded = format.encode(result.text) else {
                        throw ToolError.invalid("The replacement could not be encoded in the source format.")
                    }
                    guard encoded.count <= maximumBatchOutput - outputBytes else {
                        throw ToolError.invalid("The batch output limit was reached. Preview fewer files.")
                    }
                    outputBytes += encoded.count
                    output = encoded
                }
                files.append(File(id: index, source: input, count: result.count,
                                  before: text, after: result.text, error: nil, version: loaded.version, output: output))
            } catch {
                try Task.checkCancellation()
                files.append(File(id: index, source: input, count: 0, before: "", after: "", error: error.localizedDescription, version: nil, output: nil))
            }
        }
        return files
    }

    private static func replaceLiterally(
        _ text: String, options: BatchFindReplaceOptions
    ) throws -> (text: String, count: Int) {
        let source = text as NSString
        let comparison: NSString.CompareOptions = options.ignoresCase ? [.literal, .caseInsensitive] : [.literal]
        let maximumOutput = 4 * maximumFileBytes
        let replacementBytes = options.replacement.utf8.count
        var position = 0
        var count = 0
        var bytes = 0
        var result = ""
        while position < source.length {
            try Task.checkCancellation()
            let remaining = NSRange(location: position, length: source.length - position)
            let match = source.range(of: options.pattern, options: comparison, range: remaining)
            guard match.location != NSNotFound else { break }
            let unchanged = source.substring(with: NSRange(location: position, length: match.location - position))
            bytes += unchanged.utf8.count + replacementBytes
            guard bytes <= maximumOutput else { throw ToolError.invalid("The replacement exceeds 4 MiB.") }
            result.append(unchanged)
            result.append(options.replacement)
            position = NSMaxRange(match)
            count += 1
        }
        let tail = source.substring(from: position)
        guard tail.utf8.count <= maximumOutput - bytes else { throw ToolError.invalid("The replacement exceeds 4 MiB.") }
        result.append(tail)
        return (result, count)
    }

    @concurrent
    package static func export(_ files: [File], to destination: URL) async throws -> URL {
        guard destination.isFileURL, files.contains(where: \.changed) else {
            throw ToolError.invalid("Select a local destination and preview at least one changed file.")
        }
        let manager = FileManager.default
        let id = UUID().uuidString
        let staging = destination.appendingPathComponent(".MacUtilityKit-" + id, isDirectory: true)
        let result = destination.appendingPathComponent("Replaced Text - " + id, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        for file in files {
            guard let output = file.output else { continue }
            try Task.checkCancellation()
            let current = try await PlainTextDecoding.loadVerifiedFile(file.source, maximumBytes: maximumFileBytes)
            guard current.version.stamp == file.version?.stamp,
                  PlainTextDecoding.decode(current.bytes)?.utf8.elementsEqual(file.before.utf8) == true else {
                throw ToolError.invalid("\(file.source.lastPathComponent) changed after preview. Preview the batch again.")
            }
            let name = OutputFilename.numberedOriginal(file.source, position: file.id + 1)
            try output.write(to: staging.appendingPathComponent(name))
        }
        try Task.checkCancellation()
        try manager.moveItem(at: staging, to: result)
        return result
    }
}
