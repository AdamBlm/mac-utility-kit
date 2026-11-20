import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UtilityCore
import UniformTypeIdentifiers

@Test func imagesToPDFUsesEXIFOrientationInputOrderAndBackground() async throws {
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let portrait = folder.appendingPathComponent("Rotated.jpg")
    let transparent = folder.appendingPathComponent("Transparent.png")
    try conversionImage(portrait, kind: .jpeg, width: 72, height: 40, orientation: 6, transparent: false)
    try conversionImage(transparent, kind: .png, width: 32, height: 24, orientation: 1, transparent: true)
    let original = try Data(contentsOf: portrait)
    let output = folder.appendingPathComponent("Combined.pdf")
    var options = ImagesToPDFOptions()
    options.margin = 4
    options.backgroundRGB = 0x00FF00
    try await ImagesToPDF.export([portrait, transparent], to: output, options: options) { _ in }

    let pdf = try #require(PDFDocument(url: output))
    #expect(pdf.pageCount == 2)
    #expect(pdf.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 48, height: 80))
    #expect(pdf.page(at: 1)?.bounds(for: .mediaBox).size == CGSize(width: 40, height: 32))
    let page = try #require(pdf.page(at: 1)?.pageRef)
    let dictionary = try #require(page.dictionary)
    var resources: CGPDFDictionaryRef?
    var objects: CGPDFDictionaryRef?
    try #require(CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources))
    try #require(CGPDFDictionaryGetDictionary(try #require(resources), "XObject", &objects))
    var embeddedImages = 0
    CGPDFDictionaryApplyBlock(try #require(objects), { _, object, _ in
        var stream: CGPDFStreamRef?
        var subtype: UnsafePointer<CChar>?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
              let properties = CGPDFStreamGetDictionary(stream),
              CGPDFDictionaryGetName(properties, "Subtype", &subtype), let subtype,
              String(cString: subtype) == "Image" else { return true }
        embeddedImages += 1
        var mask: CGPDFObjectRef?
        #expect(!CGPDFDictionaryGetObject(properties, "SMask", &mask))
        #expect(!CGPDFDictionaryGetObject(properties, "Mask", &mask))
        return true
    }, nil)
    #expect(embeddedImages == 1)
    let exports = try folder.subdirectory("exports")
    var raster = PDFToImagesOptions()
    raster.range = "2"
    raster.dpi = 72
    let files = try await PDFToImages.export(output, into: exports, options: raster) { _ in }
    let image = try conversionReadImage(try #require(files.first))
    let sampled = try conversionPixel(image, x: 20, y: 16)
    #expect(sampled.green > 240 && sampled.red < 15 && sampled.blue < 15 && sampled.alpha == 255)
    let blended = try conversionPixel(image, x: 12, y: 16)
    #expect((105...150).contains(blended.red) && (105...150).contains(blended.green)
            && blended.blue < 15 && blended.alpha == 255)
    let margin = try conversionPixel(image, x: 2, y: 16)
    #expect(margin == sampled)
    #expect(try Data(contentsOf: portrait) == original)
}

@Test func imagesToPDFLayoutShowsFillClippingAndRejectsInvalidMargins() throws {
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = folder.appendingPathComponent("Wide.png")
    try conversionImage(input, kind: .png, width: 200, height: 50, orientation: 1, transparent: false)
    var options = ImagesToPDFOptions()
    options.paper = .custom
    options.width = 200
    options.height = 200
    options.margin = 20
    let fit = try ImagesToPDF.layout(input, options: options)
    #expect(fit.printableArea.contains(fit.image))
    options.placement = .fill
    let fill = try ImagesToPDF.layout(input, options: options)
    #expect(fill.image.width > fill.printableArea.width)
    #expect(fill.image.height == fill.printableArea.height)
    options.margin = 100
    #expect(throws: ToolError.self) { try ImagesToPDF.layout(input, options: options) }
}

@Test func PDFToImagesRespectsMixedCropRotationSelectionAndAnnotation() async throws {
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = try conversionPDF(in: folder)
    let original = try Data(contentsOf: input)
    let exports = try folder.subdirectory("exports")
    var options = PDFToImagesOptions()
    options.range = "2,1"
    options.dpi = 144
    options.transparent = true
    let firstPreview = try await PDFToImages.preview(input, pageNumber: 1, options: options)
    let secondPreview = try await PDFToImages.preview(input, pageNumber: 2, options: options)
    #expect(firstPreview.width == 420 && firstPreview.height == 252)
    #expect(secondPreview.width == 263 && secondPreview.height == 420)
    let previewCorner = try conversionPixel(secondPreview, x: 3, y: 3)
    #expect(previewCorner.alpha == 0)
    let files = try await PDFToImages.export(input, into: exports, options: options) { _ in }
    #expect(files.map(\.lastPathComponent) == ["Input-2.png", "Input-1.png"])
    let rotated = try conversionReadImage(files[0])
    let first = try conversionReadImage(files[1])
    #expect(rotated.width == 100 && rotated.height == 160)
    #expect(first.width == 200 && first.height == 120)
    let center = try conversionPixel(rotated, x: 50, y: 80)
    #expect(center.green > 200 && center.red < 35 && center.blue < 35 && center.alpha == 255)
    let corner = try conversionPixel(rotated, x: 3, y: 3)
    #expect(corner.alpha == 0)
    #expect(try Data(contentsOf: input) == original)
}

@Test func PDFToImagesValidatesBoundsNamingAndLossyEncoder() async throws {
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = try conversionPDF(in: folder)
    let exports = try folder.subdirectory("exports")
    var options = PDFToImagesOptions()
    options.format = .jpg
    options.resolution = .bounds
    options.maxWidth = 50
    options.maxHeight = 40
    options.filenamePattern = "{name}"
    await #expect(throws: ToolError.self) {
        try await PDFToImages.export(input, into: exports, options: options) { _ in }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: exports.path).isEmpty)
    options.range = "1"
    options.filenamePattern = String(repeating: "a", count: 252)
    let longName = await #expect(throws: ToolError.self) {
        try await PDFToImages.export(input, into: exports, options: options) { _ in }
    }
    #expect(longName?.localizedDescription.contains("filename is too long") == true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: exports.path).isEmpty)
    options.filenamePattern = String(repeating: "é", count: 83)
    let results = try await PDFToImages.export(input, into: exports, options: options) { _ in }
    let image = try conversionReadImage(try #require(results.first))
    #expect(image.width == 50 && image.height == 30)
    #expect(try #require(results.first).pathExtension == "jpg")
}

@Test func PDFToImagesPreviewAndPNGKeepPartialTransparency() async throws {
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("PartialAlpha.pdf")
    var box = CGRect(x: 0, y: 0, width: 100, height: 100)
    let context = try #require(CGContext(source as CFURL, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 0.5)
    context.fill(CGRect(x: 25, y: 25, width: 50, height: 50))
    context.endPDFPage()
    context.closePDF()

    let exports = try folder.subdirectory("exports")
    var options = PDFToImagesOptions()
    options.transparent = true
    options.resolution = .bounds
    options.maxWidth = 420
    options.maxHeight = 420
    let preview = try await PDFToImages.preview(source, pageNumber: 1, options: options)
    let outputs = try await PDFToImages.export(source, into: exports, options: options) { _ in }
    let png = try conversionReadImage(try #require(outputs.first))
    for image in [preview, png] {
        #expect(try conversionPixel(image, x: 5, y: 5).alpha == 0)
        #expect((125...130).contains(try conversionPixel(image, x: 210, y: 210).alpha))
    }
}

@Test func imagesToPDFLeavesNoOutputForAnInvalidSource() async throws {
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = folder.appendingPathComponent("Valid.png")
    try conversionImage(input, kind: .png, width: 40, height: 30, orientation: 1, transparent: false)
    let broken = folder.appendingPathComponent("Broken.png")
    try Data([1, 2, 3]).write(to: broken)
    let output = folder.appendingPathComponent("Broken.pdf")
    await #expect(throws: ToolError.self) {
        try await ImagesToPDF.export([input, broken], to: output, options: .init()) { _ in }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["Broken.png", "Valid.png"])
}

private func conversionFolder() throws -> URL {
    try FileManager.default.temporaryDirectory.subdirectory(UUID().uuidString)
}

private extension URL {
    func subdirectory(_ name: String) throws -> URL {
        let result = appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        return result
    }
}

private func conversionImage(_ url: URL, kind: UTType, width: Int, height: Int,
                             orientation: Int, transparent: Bool) throws {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    if !transparent {
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    } else {
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 0.5)
        context.fill(CGRect(x: 0, y: 0, width: width / 2 - 2, height: height))
    }
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, kind.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
}

private func conversionReadImage(_ url: URL) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

private func conversionPixel(_ image: CGImage, x: Int, y: Int) throws -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
    let pixel = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
    let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                         bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    return (bytes[0], bytes[1], bytes[2], bytes[3])
}

private func conversionPDF(in folder: URL) throws -> URL {
    let raw = folder.appendingPathComponent("Base.pdf")
    let context = try #require(CGContext(raw as CFURL, mediaBox: nil, nil))
    for size in [CGSize(width: 100, height: 60), CGSize(width: 120, height: 90)] {
        var box = CGRect(origin: .zero, size: size)
        context.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
        context.endPDFPage()
    }
    context.closePDF()
    let document = try #require(PDFDocument(url: raw))
    let page = try #require(document.page(at: 1))
    let cropBox = CGRect(x: 10, y: 15, width: 80, height: 50)
    page.setBounds(cropBox, for: .cropBox)
    page.rotation = 90
    let marker = PDFAnnotation(bounds: CGRect(x: 39, y: 29, width: 22, height: 22), forType: .square, withProperties: nil)
    marker.color = .green
    marker.interiorColor = .green
    page.addAnnotation(marker)
    let input = folder.appendingPathComponent("Input.pdf")
    #expect(document.write(to: input))
    return input
}

@Test func PDFToImagesHonorsUserUnitAndRecordsRequestedDPI() async throws {
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let pdf = folder.appendingPathComponent("Physical.pdf")
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 150] /Resources << >> /UserUnit 2 >>"
    ]
    try pdfFixtureData(objects: objects).write(to: pdf)
    let exports = try folder.subdirectory("exports")
    var options = PDFToImagesOptions()
    options.dpi = 72
    let images = try await PDFToImages.export(pdf, into: exports, options: options) { _ in }
    let path = try #require(images.first)
    let image = try conversionReadImage(path)
    #expect(image.width == 200 && image.height == 300)
    let imageSource = try #require(CGImageSourceCreateWithURL(path as CFURL, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
    let dpi = try #require(properties[kCGImagePropertyDPIWidth] as? Double)
    #expect(abs(dpi - 72) < 0.05)

    let input = try #require(PDFDocument(url: pdf))
    let inputPage = try #require(input.page(at: 0)?.pageRef)
    #expect(PDFCrop.visibleSize(for: inputPage) == CGSize(width: 200, height: 300))
    var crop = PDFCropOptions()
    crop.offsets.left = 20
    crop.offsets.top = 30
    let cropped = folder.appendingPathComponent("Cropped.pdf")
    _ = try await PDFCrop.export(pdf, to: cropped, options: crop) { _ in }
    let result = try #require(PDFDocument(url: cropped))
    let resultPage = try #require(result.page(at: 0)?.pageRef)
    #expect(resultPage.getBoxRect(.cropBox) == CGRect(x: 10, y: 0, width: 90, height: 135))
    #expect(PDFCrop.visibleSize(for: resultPage) == CGSize(width: 180, height: 270))

    // Also exercise the fallback on systems where the native writer retains the scale.
    if let path = ProcessInfo.processInfo.environment["MAC_UTILITY_QPDF_TEST"] {
        let fallback = folder.appending(path: "Cropped with qpdf.pdf")
        let box = try PDFCrop.box(for: inputPage, offsets: crop.offsets)
        try await PDFCropQPDF.write(pdf, to: fallback, boxes: [(index: 0, box: box)],
                                    directory: folder, executable: URL(fileURLWithPath: path))
        let fallbackDocument = try #require(PDFDocument(url: fallback))
        let fallbackPage = try #require(fallbackDocument.page(at: 0)?.pageRef)
        #expect(fallbackPage.getBoxRect(.cropBox) == CGRect(x: 10, y: 0, width: 90, height: 135))
        #expect(PDFCrop.visibleSize(for: fallbackPage) == CGSize(width: 180, height: 270))
    }
}

@Test func PDFToImagesBindsPlansAndPublicationToReviewedBytes() async throws {
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try conversionPDF(in: folder)
    let bytes = try Data(contentsOf: source)
    let exports = try folder.subdirectory("exports")
    var options = PDFToImagesOptions()
    options.reviewedSource = try PDFSourceStamp.read(source)
    try bytes.write(to: source, options: .atomic)
    #expect(throws: ToolError.self) { try PDFToImages.plans(source, options: options) }
    await #expect(throws: ToolError.self) {
        try await PDFToImages.preview(source, pageNumber: 1, options: options)
    }
    await #expect(throws: ToolError.self) {
        try await PDFToImages.export(source, into: exports, options: options) { _ in }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: exports.path).isEmpty)
    options.reviewedSource = try PDFSourceStamp.read(source)
    #expect(try PDFToImages.plans(source, options: options).count == 2)
    do {
        _ = try await PDFToImages.export(source, into: exports, options: options) { progress in
            if progress == 2.0 / 3.0 {
                do { try bytes.write(to: source, options: .atomic) }
                catch { Issue.record("Could not replace the PDF source: \(error)") }
            }
        }
        Issue.record("PDF to Images published output after the source changed.")
    } catch {
        #expect(error.localizedDescription.contains("Refresh the page preview"))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: exports.path).isEmpty)
}

@Test(arguments: ["reader", ""])
func PDFToImagesHonorsCopyrightRestrictionsAndCanEncodeHEIC(readerPassword: String) async throws {
    let folder = try conversionFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try conversionPDF(in: folder)
    let document = try #require(PDFDocument(url: source))
    let restricted = folder.appendingPathComponent("Protected.pdf")
    let data = try #require(document.dataRepresentation(options: [
        PDFDocumentWriteOption.userPasswordOption: readerPassword,
        PDFDocumentWriteOption.ownerPasswordOption: "owner",
        PDFDocumentWriteOption.accessPermissionsOption: 0
    ]))
    try data.write(to: restricted)
    let opened = try #require(PDFDocument(url: restricted))
    #expect(opened.isEncrypted)
    #expect(opened.isLocked == !readerPassword.isEmpty)
    let exports = try folder.subdirectory("exports")
    var options = PDFToImagesOptions()
    options.password = readerPassword
    options.range = "1"
    #expect(throws: ToolError.self) { try PDFToImages.plans(restricted, options: options) }
    await #expect(throws: ToolError.self) {
        try await PDFToImages.export(restricted, into: exports, options: options) { _ in }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: exports.path).isEmpty)
    options.password = "owner"
    #expect(try PDFToImages.plans(restricted, options: options).map(\.pageNumber) == [1])
    #expect(try await PDFToImages.preview(restricted, pageNumber: 1, options: options).width == 420)
    if (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(UTType.heic.identifier) == true {
        options.format = .heic
    }
    let outputs = try await PDFToImages.export(restricted, into: exports, options: options) { _ in }
    let output = try #require(outputs.first)
    #expect(output.pathExtension == options.format.fileExtension)
    #expect(try conversionReadImage(output).width == 200)
    #expect(try Data(contentsOf: restricted) == data)
}

func pdfFixtureData(objects: [String]) -> Data {
    var source = "%PDF-1.6\n"
    var offsets: [Int] = []
    for (index, object) in objects.enumerated() {
        offsets.append(source.utf8.count)
        source += "\(index + 1) 0 obj\n\(object)\nendobj\n"
    }
    let xref = source.utf8.count
    source += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets { source += String(format: "%010d 00000 n \n", offset) }
    source += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return Data(source.utf8)
}
