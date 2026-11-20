import Foundation
import ImageIO
import PDFKit
import Testing
import UtilityCore

@Test func visualPDFSignatureRendersOnRequestedRotatedAndUnrotatedPages() async throws {
    let directory = try signingDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("Source.pdf")
    try signingFixture(to: source)
    let original = try Data(contentsOf: source)

    let output = directory.appendingPathComponent("Signed.pdf")
    var options = PDFSignatureOptions()
    let first = PageSelection.updating([], at: 2, extendingFrom: nil)
    let span = PageSelection.updating(first, at: 0, extendingFrom: 2)
    let selected = PageSelection.updating(span, at: 1, extendingFrom: nil)
    options.pageRange = PageSelection.expression(for: selected)
    #expect(try PDFSigning.signingPageIndices(options, pageCount: 3) == [2, 0])
    options.text = "Avery Chen"
    options.dateLabel = "18 November 2026"
    options.center = CGPoint(x: 0.35, y: 0.67)
    try await PDFSigning.sign(source, to: output, options: options) { _ in }

    let signed = try #require(PDFDocument(url: output))
    #expect(signed.pageCount == 3)
    #expect(try Data(contentsOf: source) == original)
    #expect(signed.page(at: 1)?.annotations.isEmpty == true)
    for index in [0, 2] {
        let page = try #require(signed.page(at: index))
        let ref = try #require(page.pageRef)
        let annotation = try #require(page.annotations.first)
        #expect(annotation.contents == "Visual signature")
        #expect(annotation.shouldPrint)
        #expect(annotation.paths?.isEmpty == false)
        let size = PDFSigning.visibleSize(for: ref)
        let transform = ref.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                rotate: 0, preserveAspectRatio: true)
        let display = annotation.bounds.applying(transform)
        #expect(abs(display.midX / size.width - 0.35) < 0.02)
        #expect(abs(display.midY / size.height - 0.33) < 0.02)
        let name = try #require(annotation.value(forAnnotationKey: .name) as? String)
        let verification = PDFSigning.ExpectedPlacement(name: name, rotation: page.rotation,
                                                       displayedBounds: display, signatureCount: 1)
        #expect(verification.matches(page))
        let originalBounds = annotation.bounds
        annotation.bounds = originalBounds.offsetBy(dx: 12, dy: 0)
        #expect(!verification.matches(page))
        annotation.bounds = originalBounds
        annotation.shouldPrint = false
        #expect(!verification.matches(page))
        annotation.shouldPrint = true
        page.rotation = (page.rotation + 90) % 360
        #expect(!verification.matches(page))
    }

    let raster = directory.appendingPathComponent("Raster", isDirectory: true)
    try FileManager.default.createDirectory(at: raster, withIntermediateDirectories: false)
    var images = PDFToImagesOptions()
    images.range = "1, 2, 3"
    let outputs = try await PDFToImages.export(output, into: raster, options: images) { _ in }
    #expect(outputs.count == 3)
    #expect(try signingInkPixelCount(outputs[0]) > 10)
    #expect(try signingInkPixelCount(outputs[1]) == 0)
    #expect(try signingInkPixelCount(outputs[2]) > 10)
}

@Test func drawnPDFSignatureChecksInputAndDoesNotOverwrite() async throws {
    let directory = try signingDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("Source.pdf")
    try signingFixture(to: source)
    let output = directory.appendingPathComponent("Signed.pdf")
    var options = PDFSignatureOptions()
    options.mode = .drawn
    await #expect(throws: ToolError.self) {
        try await PDFSigning.sign(source, to: output, options: options) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))

    options.strokes = [[CGPoint(x: 0.2, y: 0.6), CGPoint(x: 0.4, y: 0.2), CGPoint(x: 0.65, y: 0.8)]]
    try await PDFSigning.sign(source, to: output, options: options) { _ in }
    let document = try #require(PDFDocument(url: output))
    #expect(document.page(at: 0)?.annotations.first?.paths?.isEmpty == false)
    let signed = try Data(contentsOf: output)
    await #expect(throws: ToolError.self) {
        try await PDFSigning.sign(source, to: output, options: options) { _ in }
    }
    #expect(try Data(contentsOf: output) == signed)
    #expect(throws: ToolError.self) { try PDFSigning.pageIndices("none", pageCount: 3) }
    #expect(throws: ToolError.self) { try PDFSigning.pageIndices("4", pageCount: 3) }
}

@Test func visualPDFSignatureUsesPerPagePlacementAndOmitsRemovedPage() async throws {
    let directory = try signingDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "Source.pdf")
    try signingFixture(to: source)
    let original = try Data(contentsOf: source)
    let output = directory.appending(path: "Signed.pdf")
    var options = PDFSignatureOptions()
    options.text = "Avery Chen"
    options.pageRange = "1–3"
    options.center = CGPoint(x: 0.20, y: 0.22)
    options.width = 0.14
    options.pageOverrides[2] = .excluded
    options.pageOverrides[3] = .custom(.init(center: CGPoint(x: 0.73, y: 0.78), width: 0.36))
    try await PDFSigning.sign(source, to: output, options: options) { _ in }

    let document = try #require(PDFDocument(url: output))
    #expect(try Data(contentsOf: source) == original)
    #expect(document.page(at: 1)?.annotations.isEmpty == true)
    for (index, x, y, width) in [(0, 0.20, 0.78, 0.14), (2, 0.73, 0.22, 0.36)] {
        let page = try #require(document.page(at: index))
        let ref = try #require(page.pageRef)
        let annotation = try #require(page.annotations.first)
        let size = PDFSigning.visibleSize(for: ref)
        let transform = ref.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                rotate: 0, preserveAspectRatio: true)
        let display = annotation.bounds.applying(transform)
        #expect(abs(display.midX / size.width - x) < 0.025)
        #expect(abs(display.midY / size.height - y) < 0.025)
        #expect(abs(display.width / size.width - width) < 0.03)
    }

    options.pageRange = "2"
    let excluded = directory.appending(path: "Excluded.pdf")
    await #expect(throws: ToolError.self) {
        try await PDFSigning.sign(source, to: excluded, options: options) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: excluded.path))
    options.pageOverrides[2] = nil
    #expect(options.placement(forPage: 2) == options.sharedPlacement)
}

@Test func visualPDFSignatureRequiresRefreshAfterSamePageCountReplacement() async throws {
    let directory = try signingDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "Source.pdf")
    let replacement = directory.appending(path: "Replacement.pdf")
    let output = directory.appending(path: "Signed.pdf")
    try signingFixture(to: source)
    var options = PDFSignatureOptions()
    options.text = "Avery Chen"
    options.sourceStamp = try PDFSignatureSourceStamp.read(source)
    let different = try #require(PDFDocument(url: source))
    let page = try #require(different.page(at: 0))
    page.rotation = 180
    try #require(different.write(to: replacement))
    _ = try FileManager.default.replaceItemAt(source, withItemAt: replacement)

    do {
        try await PDFSigning.sign(source, to: output, options: options) { _ in }
        Issue.record("A replaced source should not be signed using the previous preview.")
    } catch {
        #expect(error.localizedDescription.contains("Refresh the PDF preview"))
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    options.sourceStamp = try PDFSignatureSourceStamp.read(source)
    try await PDFSigning.sign(source, to: output, options: options) { _ in }
    let signed = try #require(PDFDocument(url: output))
    #expect(signed.pageCount == 3)
    #expect(signed.page(at: 0)?.rotation == 180)
}

private func signingDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private func signingFixture(to url: URL) throws {
    var media = CGRect(x: 0, y: 0, width: 220, height: 300)
    let blank = url.deletingLastPathComponent().appendingPathComponent("Blank.pdf")
    let context = try #require(CGContext(blank as CFURL, mediaBox: &media, nil))
    for _ in 0..<3 {
        context.beginPDFPage(nil)
        context.endPDFPage()
    }
    context.closePDF()
    let doc = try #require(PDFDocument(url: blank))
    let page = try #require(doc.page(at: 2))
    page.rotation = 90
    page.setBounds(CGRect(x: 15, y: 20, width: 185, height: 255), for: .cropBox)
    try #require(doc.write(to: url))
}

private func signingInkPixelCount(_ url: URL) throws -> Int {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    var count = 0
    for row in 0..<image.height {
        for column in 0..<image.width {
            let pixel = bytes + row * context.bytesPerRow + column * 4
            if pixel[0] < 150, pixel[2] > pixel[0] { count += 1 }
        }
    }
    return count
}
