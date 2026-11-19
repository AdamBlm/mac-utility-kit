import Foundation

public struct DocumentConvertOptions: Equatable, Sendable {
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case docx = "Word (.docx)"
        case odt = "OpenDocument (.odt)"
        case rtf = "Rich Text (.rtf)"
        case html = "HTML (.html)"
        case plain = "Plain Text (.txt)"
        case markdown = "Markdown (.md)"

        public var id: Self { self }
        public var fileExtension: String {
            switch self {
            case .docx: "docx"
            case .odt: "odt"
            case .rtf: "rtf"
            case .html: "html"
            case .plain: "txt"
            case .markdown: "md"
            }
        }
    }

    public var target = Format.docx
    fileprivate static let defaultFilenamePattern = "{index} - {name}"
    public var filenamePattern = Self.defaultFilenamePattern
    public var pandocExecutable: URL?
    public var libreOfficeExecutable: URL?
    public var prefersLibreOffice = false

    public init() {}
}

public enum DocumentConvert {
    public enum Engine: String, Sendable {
        case native = "macOS"
        case pandoc = "Pandoc"
        case libreOffice = "LibreOffice"
        case both = "LibreOffice + Pandoc"
    }

    public struct Preview: Sendable {
        public let text: String
        public let truncated: Bool
    }

    enum Source: Equatable {
        case format(DocumentConvertOptions.Format)
        case legacyWord

        init(_ url: URL) throws {
            guard url.isFileURL else { throw ToolError.invalid("Choose a local document.") }
            switch url.pathExtension.lowercased() {
            case "doc": self = .legacyWord
            case "docx": self = .format(.docx)
            case "odt": self = .format(.odt)
            case "rtf": self = .format(.rtf)
            case "html", "htm": self = .format(.html)
            case "txt", "text": self = .format(.plain)
            case "md", "markdown": self = .format(.markdown)
            default: throw ToolError.invalid("Choose a Word, OpenDocument, RTF, HTML, Plain Text, or Markdown file.")
            }
        }
    }

    public static func requiredEngine(for input: URL, options: DocumentConvertOptions) throws -> Engine {
        try engine(for: Source(input), options: options)
    }

    private static func engine(for source: Source, options: DocumentConvertOptions) throws -> Engine {
        guard source != .format(options.target) else {
            throw ToolError.invalid("Choose a different output format.")
        }
        if source == .format(.plain), options.target == .markdown || options.target == .html { return .native }
        if source == .legacyWord { return options.target == .markdown ? .both : .libreOffice }
        if (options.prefersLibreOffice || options.pandocExecutable == nil && options.libreOfficeExecutable != nil),
           source != .format(.markdown), options.target != .markdown {
            return .libreOffice
        }
        return .pandoc
    }

    public static func optionIssue(for input: URL, options: DocumentConvertOptions) -> String? {
        do {
            let engine = try requiredEngine(for: input, options: options)
            if engine == .pandoc || engine == .both {
                guard let pandoc = options.pandocExecutable, ExternalTool.isExecutable(pandoc) else {
                    return "Choose a Pandoc executable for this conversion."
                }
            }
            if engine == .libreOffice || engine == .both {
                guard let office = options.libreOfficeExecutable, LibreOfficeHeadless.hasExecutable(office) else {
                    return "Choose LibreOffice or its soffice executable for this conversion."
                }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public static func outputStem(_ input: URL, position: Int, options: DocumentConvertOptions) throws -> String {
        guard position >= 1 else { throw ToolError.invalid("The file number must be positive.") }
        let name = input.deletingPathExtension().lastPathComponent
        let pattern = options.filenamePattern
        guard pattern.utf8.count <= 240 else { throw ToolError.invalid("The filename template is too long.") }
        let targetExtension = "." + options.target.fileExtension
        var remaining = pattern[...]
        var expanded = ""
        while !remaining.isEmpty {
            if remaining.hasPrefix("{name}") {
                expanded += name
                remaining = remaining.dropFirst(6)
            } else if remaining.hasPrefix("{index}") {
                expanded += String(position)
                remaining = remaining.dropFirst(7)
            } else if let character = remaining.popFirst() {
                expanded.append(character)
            }
        }
        var stem = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.lowercased().hasSuffix(targetExtension) { stem = String(stem.dropLast(targetExtension.count)) }
        guard !stem.isEmpty, stem != ".", stem != "..", !stem.contains("/"),
              stem.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ToolError.invalid("The filename template produces an invalid filename.")
        }
        if pattern == DocumentConvertOptions.defaultFilenamePattern {
            return OutputFilename.shortenedStem(stem, suffix: targetExtension)
        }
        guard OutputFilename.fits(stem + targetExtension) else {
            throw ToolError.invalid("The document filename is too long. Shorten the filename template.")
        }
        return stem
    }

    package static func exportIssue(for input: URL, position: Int, options: DocumentConvertOptions) -> String? {
        do {
            _ = try outputStem(input, position: position, options: options)
        } catch {
            return error.localizedDescription
        }
        return previewIssue(for: input, options: options)
    }

    package static func previewIssue(for input: URL, options: DocumentConvertOptions) -> String? {
        do {
            try validateInputFile(input)
        } catch {
            return error.localizedDescription
        }
        return optionIssue(for: input, options: options)
    }

    package static func conflictingOutputFilenames(_ inputs: [URL], options: DocumentConvertOptions) -> [String] {
        var seen: [String: String] = [:]
        var reported: Set<String> = []
        var conflicts: [String] = []
        for (index, input) in inputs.enumerated() {
            guard let stem = try? outputStem(input, position: index + 1, options: options) else { continue }
            let filename = stem + "." + options.target.fileExtension
            let key = filename.precomposedStringWithCanonicalMapping.lowercased()
            if let earlier = seen[key] {
                if reported.insert(key).inserted { conflicts.append(earlier) }
            } else {
                seen[key] = filename
            }
        }
        return conflicts
    }

    public static func export(
        _ input: URL, to output: URL, options: DocumentConvertOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        guard output.isFileURL, input.standardizedFileURL != output.standardizedFileURL,
              !FileManager.default.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a new local document file.")
        }
        let stage = try staging(in: output.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: stage) }
        let suffix = options.target.fileExtension
        let candidate = stage.appending(path: "Converted." + suffix)
        let engine = try await convert(input, to: candidate, options: options, in: stage, progress: progress)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: candidate, to: output)
        await progress(1)
        let loss = options.target == .plain ? " · Formatting removed" : ""
        return "\(input.lastPathComponent) · \(options.target.rawValue) · \(engine.rawValue)\(loss)"
    }

    public static func preview(_ input: URL, options: DocumentConvertOptions) async throws -> Preview {
        let stage = try staging(in: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: stage) }
        let candidate = stage.appending(path: "Converted." + options.target.fileExtension)
        let used = try await convert(input, to: candidate, options: options, in: stage) { _ in }
        let text: String
        switch options.target {
        case .plain, .markdown:
            text = try readText(candidate)
        case .html, .docx, .odt, .rtf:
            let sample = stage.appending(path: "Preview.txt")
            if let pandoc = options.pandocExecutable, used == .pandoc || used == .both {
                try await DocumentConversionEngines.pandoc(candidate, from: .format(options.target), to: sample,
                                                           target: .plain, executable: pandoc)
                text = try readText(sample)
            } else if let libreOffice = options.libreOfficeExecutable, used == .libreOffice {
                try await DocumentConversionEngines.libreOffice(candidate, to: sample, target: .plain,
                                                                executable: libreOffice, stage: stage)
                text = try readText(sample)
            } else if options.target == .html {
                text = try readText(candidate)
            } else {
                throw ToolError.invalid("Choose Pandoc or LibreOffice to preview this converted document.")
            }
        }
        try Task.checkCancellation()
        let excerpt = text.prefix(20_000)
        return Preview(text: String(excerpt), truncated: excerpt.endIndex != text.endIndex)
    }

    private static func convert(
        _ input: URL, to output: URL, options: DocumentConvertOptions, in stage: URL,
        progress: @Sendable (Double) async -> Void
    ) async throws -> Engine {
        let source = try Source(input)
        try validateInputFile(input)
        if let issue = optionIssue(for: input, options: options) { throw ToolError.invalid(issue) }
        let engine = try engine(for: source, options: options)
        try Task.checkCancellation()
        await progress(0.15)
        switch engine {
        case .native:
            let plain = try readText(input)
            let value = options.target == .html ? html(wrapping: plain) : markdown(wrapping: plain)
            try Data(value.utf8).write(to: output)
        case .pandoc:
            guard let executable = options.pandocExecutable else { throw ToolError.invalid("Choose a Pandoc executable.") }
            if source == .format(.plain) {
                let prepared = stage.appending(path: "Plain.html")
                try Data(html(wrapping: readText(input)).utf8).write(to: prepared)
                try await DocumentConversionEngines.pandoc(prepared, from: .format(.html), to: output,
                                                           target: options.target, executable: executable)
            } else {
                try await DocumentConversionEngines.pandoc(input, from: source, to: output, target: options.target, executable: executable)
            }
        case .libreOffice:
            guard let executable = options.libreOfficeExecutable else { throw ToolError.invalid("Choose LibreOffice.") }
            let prepared: URL
            if source == .format(.plain) {
                prepared = stage.appending(path: "Plain.txt")
                try Data(readText(input).utf8).write(to: prepared)
            } else {
                prepared = input
            }
            try await DocumentConversionEngines.libreOffice(prepared, to: output, target: options.target, executable: executable, stage: stage)
        case .both:
            guard let office = options.libreOfficeExecutable, let pandoc = options.pandocExecutable else {
                throw ToolError.invalid("Choose LibreOffice and Pandoc.")
            }
            let intermediate = stage.appending(path: "Intermediate.docx")
            try await DocumentConversionEngines.libreOffice(input, to: intermediate, target: .docx, executable: office, stage: stage)
            await progress(0.55)
            try await DocumentConversionEngines.pandoc(intermediate, from: .format(.docx), to: output,
                                                       target: options.target, executable: pandoc)
        }
        try Task.checkCancellation()
        try DocumentConversionEngines.verify(output, format: options.target)
        return engine
    }

    private static func validateInputFile(_ input: URL) throws {
        guard input.isFileURL, let resources = try? input.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              resources.isRegularFile == true, let size = resources.fileSize, size <= 128 * 1024 * 1024 else {
            throw ToolError.invalid("Choose a local document up to 128 MB.")
        }
    }

    private static func staging(in parent: URL) throws -> URL {
        let folder = parent.appending(path: ".document-convert-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16), !text.contains("\0") { return text }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw ToolError.invalid("The text file must be UTF-8 or UTF-16 with a byte-order mark.")
        }
        return text
    }

    private static func html(wrapping text: String) -> String {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>Document</title></head><body><pre>\n" +
            escaped + "</pre></body></html>\n"
    }

    private static func markdown(wrapping text: String) -> String {
        var longest = 0
        var run = 0
        for scalar in text.utf8 {
            run = scalar == 0x60 ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + "\n" + text + (text.hasSuffix("\n") ? "" : "\n") + fence + "\n"
    }
}
