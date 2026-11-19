import CoreGraphics
import Foundation
import PDFKit

public struct PDFCompressionOptions: Equatable, Sendable {
    public enum Preset: String, CaseIterable, Identifiable, Sendable {
        case smaller = "Smaller"
        case balanced = "Balanced"
        case higherQuality = "Higher Quality"
        public var id: Self { self }
    }

    public enum Engine: String, CaseIterable, Identifiable, Sendable {
        case qpdf = "qpdf"
        case ghostscript = "Ghostscript"
        public var id: Self { self }
    }

    public var preset = Preset.higherQuality
    public var engine = Engine.qpdf
    public var imageQuality: Int?
    public var imageDPI: Int?
    public var keepsOriginalIfLarger = true
    public var qpdfExecutable: URL?
    public var ghostscriptExecutable: URL?

    public init() {}

    public var isLossless: Bool { engine == .qpdf && preset == .higherQuality && imageQuality == nil }

    public var defaultQuality: Int {
        switch preset {
        case .smaller: 58
        case .balanced: 78
        case .higherQuality: 92
        }
    }

    public var defaultDPI: Int {
        switch preset {
        case .smaller: 96
        case .balanced: 150
        case .higherQuality: 240
        }
    }

    public var validationIssue: String? {
        if let imageQuality, !(1...100).contains(imageQuality) { return "Choose JPEG quality from 1 to 100." }
        if engine == .ghostscript, let imageDPI, !(72...600).contains(imageDPI) { return "Choose a target DPI between 72 and 600." }
        if engine == .qpdf && qpdfExecutable == nil { return "Choose a qpdf executable." }
        if engine == .ghostscript && ghostscriptExecutable == nil { return "Choose a Ghostscript executable." }
        return nil
    }
}

public enum PDFCompression {
    public struct Sample: Sendable {
        public let originalBytes: Int64
        public let candidateBytes: Int64
        public let samplePages: Int
        public let totalPages: Int
        public let estimatedBytes: Int64
        public let preview: CGImage?
    }

    public static func sample(_ input: URL, options: PDFCompressionOptions) async throws -> Sample {
        try validate(options)
        let sourceStamp = try PDFSourceStamp.read(input)
        let document = try open(sourceStamp.resolved)
        try PDFCompressionEngines.validateInput(document, options: options)
        try verifySource(input, stamp: sourceStamp)
        let originalBytes = sourceStamp.bytes
        let pages = Array(Set([0, document.pageCount / 2, document.pageCount - 1])).sorted()
        let manager = FileManager.default
        let staging = try stage(in: manager.temporaryDirectory)
        defer { try? manager.removeItem(at: staging) }
        let excerpt: URL
        if pages.count == document.pageCount {
            excerpt = sourceStamp.resolved
        } else {
            excerpt = staging.appending(path: "Sample.pdf")
            if let qpdf = options.qpdfExecutable {
                let range = pages.map { String($0 + 1) }.joined(separator: ",")
                try await ExternalTool.run(qpdf, name: "qpdf", arguments: [
                    "--stream-data=preserve", "--object-streams=preserve",
                    "--empty", "--pages", sourceStamp.resolved.path, range, "--", excerpt.path
                ], directory: staging)
            } else {
                let selected = PDFDocument()
                for (index, pageIndex) in pages.enumerated() {
                    guard let page = document.page(at: pageIndex), let representation = page.dataRepresentation,
                          let single = PDFDocument(data: representation), let copy = single.page(at: 0) else {
                        throw ToolError.invalid("Could not prepare the preview pages.")
                    }
                    selected.insert(copy, at: index)
                }
                guard selected.write(to: excerpt) else { throw ToolError.invalid("Could not write the preview pages.") }
            }
        }
        let candidate = staging.appending(path: "Compressed sample.pdf")
        try verifySource(input, stamp: sourceStamp)
        try await PDFCompressionEngines.run(excerpt, to: candidate, options: options)
        try verifySource(input, stamp: sourceStamp)
        let measured = excerpt == sourceStamp.resolved ? originalBytes : try bytes(excerpt)
        let compressed = try bytes(candidate)
        let verified = try open(candidate)
        try verify(verified, against: open(excerpt), engine: options.engine)
        try verifySource(input, stamp: sourceStamp)
        let estimate = pages.count == document.pageCount
            ? compressed : Int64(min(Double(Int64.max - 1024), (Double(originalBytes) * Double(compressed) / Double(measured)).rounded()))
        return Sample(originalBytes: measured, candidateBytes: compressed, samplePages: pages.count,
                      totalPages: document.pageCount, estimatedBytes: estimate,
                      preview: verified.page(at: 0).flatMap(render))
    }

    public static func export(
        _ input: URL, to output: URL, options: PDFCompressionOptions,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        try validate(options)
        let manager = FileManager.default
        guard output.isFileURL, input.standardizedFileURL != output.standardizedFileURL,
              !manager.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a new local PDF output file.")
        }
        let sourceStamp = try PDFSourceStamp.read(input)
        let original = try open(sourceStamp.resolved)
        try PDFCompressionEngines.validateInput(original, options: options)
        let originalBytes = sourceStamp.bytes
        let staging = try stage(in: output.deletingLastPathComponent())
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appending(path: "Compressed.pdf")
        try Task.checkCancellation()
        await progress(0.1)
        try verifySource(input, stamp: sourceStamp)
        try await PDFCompressionEngines.run(sourceStamp.resolved, to: candidate, options: options)
        try Task.checkCancellation()
        await progress(0.8)
        try verifySource(input, stamp: sourceStamp)
        let compressed = try open(candidate)
        try verify(compressed, against: original, engine: options.engine)
        let candidateBytes = try bytes(candidate)
        let keptOriginal = candidateBytes >= originalBytes && options.keepsOriginalIfLarger
        let result: URL
        if keptOriginal {
            result = staging.appending(path: "Original.pdf")
            try sourceStamp.copyVerified(to: result)
        } else {
            result = candidate
        }
        try Task.checkCancellation()
        try verifySource(input, stamp: sourceStamp)
        try manager.moveItem(at: result, to: output)
        await progress(1)
        return summary(input.lastPathComponent, original: originalBytes, candidate: candidateBytes, keptOriginal: keptOriginal)
    }

    private static func verifySource(_ input: URL, stamp: PDFSourceStamp) throws {
        guard (try? PDFSourceStamp.read(input)) == stamp else {
            throw ToolError.invalid("The source PDF changed during compression. Try again.")
        }
    }

    private struct Link {
        let url: String?
        let page: Int?
        let action: String?
        let bounds: CGRect

        func matches(_ other: Self) -> Bool {
            url == other.url && page == other.page && action == other.action
                && abs(bounds.minX - other.bounds.minX) < 0.02
                && abs(bounds.minY - other.bounds.minY) < 0.02
                && abs(bounds.maxX - other.bounds.maxX) < 0.02
                && abs(bounds.maxY - other.bounds.maxY) < 0.02
        }
    }

    private static func verify(_ result: PDFDocument, against original: PDFDocument, engine: PDFCompressionOptions.Engine) throws {
        guard result.pageCount == original.pageCount else {
            throw ToolError.invalid("The compressed PDF changed its page count.")
        }
        for index in 0..<original.pageCount {
            try Task.checkCancellation()
            guard let source = original.page(at: index), let output = result.page(at: index),
                  comparableSize(source, output),
                  normalized(source.string) == normalized(output.string),
                  links(in: source, document: original).elementsEqual(links(in: output, document: result),
                                                                     by: { $0.matches($1) }) else {
                let advice = engine == .ghostscript ? " Try qpdf lossless compression." : ""
                throw ToolError.invalid("Compression changed the layout, selectable text, or links on page \(index + 1).\(advice)")
            }
        }
    }

    private static func comparableSize(_ source: PDFPage, _ output: PDFPage) -> Bool {
        guard let sourceRef = source.pageRef, let outputRef = output.pageRef else { return false }
        let lhs = PDFSigning.visibleSize(for: sourceRef)
        let rhs = PDFSigning.visibleSize(for: outputRef)
        return abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
    }

    private static func normalized(_ text: String?) -> String {
        (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func links(in page: PDFPage, document: PDFDocument) -> [Link] {
        page.annotations.filter { $0.type == "Link" }.map { link in
            let url = link.url ?? (link.action as? PDFActionURL)?.url
            let destination = link.destination ?? (link.action as? PDFActionGoTo)?.destination
            return Link(url: url?.absoluteString, page: destination?.page.map { document.index(for: $0) },
                        action: link.action.map { String(describing: type(of: $0)) }, bounds: link.bounds)
        }
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        guard let reference = page.pageRef else { return nil }
        let size = PDFSigning.visibleSize(for: reference)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let factor = min(1, 700 / max(size.width, size.height))
        let width = max(1, Int((size.width * factor).rounded()))
        let height = max(1, Int((size.height * factor).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    private static func validate(_ options: PDFCompressionOptions) throws {
        if let issue = options.validationIssue { throw ToolError.invalid(issue) }
    }

    private static func open(_ input: URL) throws -> PDFDocument {
        guard input.isFileURL, let document = PDFDocument(url: input), document.pageCount > 0 else {
            throw ToolError.invalid("Choose a readable PDF with at least one page.")
        }
        guard !document.isEncrypted, !document.isLocked, document.allowsDocumentChanges else {
            throw ToolError.invalid("Choose an unencrypted PDF that allows editing.")
        }
        return document
    }

    private static func bytes(_ file: URL) throws -> Int64 {
        guard let count = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, count > 0 else {
            throw ToolError.invalid("Could not read the PDF size.")
        }
        return Int64(count)
    }

    private static func stage(in folder: URL) throws -> URL {
        let directory = folder.appending(path: ".pdf-compress-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private static func summary(_ filename: String, original: Int64, candidate: Int64, keptOriginal: Bool) -> String {
        let before = ByteCountFormatter.string(fromByteCount: original, countStyle: .file)
        let after = ByteCountFormatter.string(fromByteCount: candidate, countStyle: .file)
        let change = abs(Double(original - candidate) / Double(original)).formatted(.percent.precision(.fractionLength(1)))
        if keptOriginal { return "\(filename) · Original kept at \(before) · No savings (candidate \(after))" }
        if candidate == original { return "\(filename) · \(before) · No savings" }
        return "\(filename) · \(before) → \(after) · \(change) \(candidate < original ? "smaller" : "larger")"
    }
}
