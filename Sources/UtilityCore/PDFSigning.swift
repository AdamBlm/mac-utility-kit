import AppKit
import CoreText
import PDFKit

public enum PDFSignatureMode: String, CaseIterable, Identifiable, Sendable {
    case typed = "Type"
    case drawn = "Draw"

    public var id: Self { self }
}

public struct PDFSignatureOptions: Sendable {
    public var password = ""
    public var pageRange = "1"
    public var mode: PDFSignatureMode = .typed
    public var text = ""
    public var strokes: [[CGPoint]] = []
    public var center = CGPoint(x: 0.72, y: 0.82)
    public var width = 0.28
    public var dateLabel = ""

    public init() {}
}

public struct PDFSignatureAppearance {
    public let path: CGPath
    public let lineWidth: Double
}

public enum PDFSigning {
    private static let annotationLabel = "Visual signature"

    public static func sign(
        _ input: URL, to output: URL, options: PDFSignatureOptions,
        progress: @Sendable (Double) async -> Void
    ) async throws {
        try Task.checkCancellation()
        guard input.isFileURL, let document = PDFDocument(url: input) else {
            throw ToolError.invalid("Could not open this PDF.")
        }
        if document.isLocked || (document.isEncrypted && !options.password.isEmpty),
           !document.unlock(withPassword: options.password) {
            throw ToolError.invalid("Could not open this PDF. Check the password.")
        }
        guard document.allowsCommenting else {
            throw ToolError.invalid("This PDF does not allow annotations.")
        }
        guard output.isFileURL, !FileManager.default.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Choose a new local output PDF.")
        }
        let pages = try pageIndices(options.pageRange, pageCount: document.pageCount)
        let mark = try signaturePath(options)
        var counts: [Int: Int] = [:]
        for (index, pageIndex) in pages.enumerated() {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex), let pageRef = page.pageRef else {
                throw ToolError.invalid("Could not open page \(pageIndex + 1).")
            }
            let size = visibleSize(for: pageRef)
            let appearance = try place(mark, on: size, options: options)
            var transform = pageRef.getDrawingTransform(.cropBox,
                rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true).inverted()
            guard let positioned = appearance.path.copy(using: &transform) else {
                throw ToolError.invalid("Could not place the signature.")
            }
            let bounds = positioned.boundingBoxOfPath.insetBy(dx: -appearance.lineWidth, dy: -appearance.lineWidth)
            var local = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
            guard let path = positioned.copy(using: &local) else {
                throw ToolError.invalid("Could not prepare the signature outline.")
            }
            let ink = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
            ink.contents = annotationLabel
            ink.color = NSColor(srgbRed: 0.11, green: 0.14, blue: 0.25, alpha: 1)
            ink.shouldPrint = true
            let border = PDFBorder()
            border.lineWidth = appearance.lineWidth
            ink.border = border
            ink.add(NSBezierPath(cgPath: path.flattened(threshold: 0.12)))
            let expected = signatures(in: page) + 1
            page.addAnnotation(ink)
            counts[pageIndex] = expected
            await progress(Double(index + 1) / Double(pages.count + 1))
        }

        let manager = FileManager.default
        let staging = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let candidate = staging.appendingPathComponent("Signed.pdf")
        guard document.write(to: candidate),
              let reopened = PDFDocument(url: candidate),
              reopened.pageCount == document.pageCount,
              counts.allSatisfy({ pageIndex, count in
                  reopened.page(at: pageIndex).map { signatures(in: $0) == count } ?? false
              }) else {
            throw ToolError.invalid("Could not verify the visible signature in the output PDF.")
        }
        try Task.checkCancellation()
        try manager.moveItem(at: candidate, to: output)
        await progress(1)
    }

    public static func pageIndices(_ range: String, pageCount: Int) throws -> [Int] {
        guard !range.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalid("Choose at least one page to sign.")
        }
        let selected = try PageSelection.indices(range, pageCount: pageCount)
        guard !selected.isEmpty else { throw ToolError.invalid("Choose at least one page to sign.") }
        return selected
    }

    public static func visibleSize(for page: CGPDFPage) -> CGSize {
        let crop = page.getBoxRect(.cropBox).intersection(page.getBoxRect(.mediaBox))
        return abs(page.rotationAngle % 180) == 90
            ? CGSize(width: crop.height, height: crop.width) : crop.size
    }

    public static func appearance(on size: CGSize, options: PDFSignatureOptions) throws -> PDFSignatureAppearance {
        try place(signaturePath(options), on: size, options: options)
    }

    private static func signatures(in page: PDFPage) -> Int {
        page.annotations.filter { $0.contents == annotationLabel && $0.paths?.isEmpty == false }.count
    }

    private static func place(
        _ mark: CGPath, on size: CGSize, options: PDFSignatureOptions
    ) throws -> PDFSignatureAppearance {
        guard size.width.isFinite, size.height.isFinite, size.width > 4, size.height > 4,
              options.width.isFinite, (0.05...0.95).contains(options.width),
              (0...1).contains(options.center.x), (0...1).contains(options.center.y)
        else { throw ToolError.invalid("The signature placement is outside the page.") }

        let bounds = mark.boundingBoxOfPath
        let scale = min(size.width * options.width / max(bounds.width, 1),
                        size.height * 0.32 / max(bounds.height, 1))
        let width = bounds.width * scale
        let height = bounds.height * scale
        let lineWidth = min(2.5, max(0.8, scale * (options.mode == .drawn ? 4 : 1.5)))
        let inset = min(2, min((size.width - width) / 2, (size.height - height) / 2))
        let centerX = min(size.width - inset - width / 2, max(inset + width / 2, size.width * options.center.x))
        let centerY = min(size.height - inset - height / 2, max(inset + height / 2, size.height * (1 - options.center.y)))
        var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                          tx: centerX - bounds.midX * scale, ty: centerY - bounds.midY * scale)
        guard let path = mark.copy(using: &transform) else { throw ToolError.invalid("Could not scale the signature.") }
        return PDFSignatureAppearance(path: path, lineWidth: lineWidth)
    }

    private static func signaturePath(_ options: PDFSignatureOptions) throws -> CGPath {
        let main: CGPath
        switch options.mode {
        case .typed:
            main = try textOutline(options.text, fontName: "SnellRoundhand", size: 64)
        case .drawn:
            let path = CGMutablePath()
            guard options.strokes.reduce(0, { $0 + $1.count }) <= 8_000 else {
                throw ToolError.invalid("The signature drawing has too many points.")
            }
            for stroke in options.strokes where stroke.count >= 2 {
                guard stroke.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
                    throw ToolError.invalid("The signature drawing contains invalid points.")
                }
                path.addLines(between: stroke.map { CGPoint(x: $0.x * 350, y: (1 - $0.y) * 100) })
            }
            guard !path.isEmpty, path.boundingBoxOfPath.width + path.boundingBoxOfPath.height > 0
            else { throw ToolError.invalid("Draw a signature to place on the page.") }
            main = path
        }
        guard !options.dateLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return main }
        let date = try textOutline(options.dateLabel, fontName: "Helvetica", size: 16)
        let combined = CGMutablePath()
        let mainBounds = main.boundingBoxOfPath
        let dateBounds = date.boundingBoxOfPath
        let factor = min(1, max(mainBounds.width, 30) / max(dateBounds.width, 1))
        combined.addPath(main)
        combined.addPath(date, transform: CGAffineTransform(a: factor, b: 0, c: 0, d: factor,
            tx: mainBounds.minX - dateBounds.minX * factor, ty: mainBounds.minY - 6 - dateBounds.maxY * factor))
        return combined
    }

    private static func textOutline(_ raw: String, fontName: String, size: Double) throws -> CGPath {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 120, text.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ToolError.invalid("Enter a signature or date label of up to 120 characters on one line.")
        }
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let path = CGMutablePath()
        if let runs = CTLineGetGlyphRuns(line) as? [CTRun] {
            for run in runs {
                let runAttributes = CTRunGetAttributes(run) as NSDictionary
                guard let value = runAttributes[kCTFontAttributeName] as AnyObject?,
                      CFGetTypeID(value) == CTFontGetTypeID() else {
                    throw ToolError.invalid("This text could not be drawn. Try drawing a signature.")
                }
                let runFont = value as! CTFont
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                let source = text as NSString
                for i in glyphs.indices {
                    if glyphs[i] != 0 {
                        var offset = CGAffineTransform(translationX: positions[i].x, y: positions[i].y)
                        if let outline = CTFontCreatePathForGlyph(runFont, glyphs[i], &offset), !outline.isEmpty {
                            path.addPath(outline)
                            continue
                        }
                    }
                    let index = indices[i]
                    guard index >= 0, index < source.length, let scalar = UnicodeScalar(source.character(at: index)),
                          CharacterSet.whitespaces.contains(scalar) || scalar.properties.generalCategory == .format else {
                        throw ToolError.invalid("The signature includes an unsupported character. Try drawing it instead.")
                    }
                }
            }
        }
        guard !path.isEmpty else {
            throw ToolError.invalid("This text could not be drawn. Try different characters or draw a signature.")
        }
        return path
    }
}
